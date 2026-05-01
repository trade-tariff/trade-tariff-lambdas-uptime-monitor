locals {
  pagerduty_secret_value = try(data.aws_secretsmanager_secret_version.pagerduty.secret_string, "{}")
  pagerduty_secret_map   = jsondecode(local.pagerduty_secret_value)
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Lambda: URL checker
# Triggered every minute by EventBridge; probes each URL and emits
# Availability and ResponseTime metrics to the TradeTariff/Uptime namespace.
# ---------------------------------------------------------------------------

data "archive_file" "checker" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/checker"
  output_path = "${path.root}/../lambda/checker.zip"
}

resource "aws_iam_role" "checker" {
  name               = "trade-tariff-uptime-checker-${var.environment}"
  path               = "/service-role/"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "checker_logs" {
  role       = aws_iam_role.checker.name
  policy_arn = aws_iam_policy.checker_logs.arn
}

resource "aws_iam_policy" "checker_logs" {
  name   = "trade-tariff-uptime-checker-logs-${var.environment}"
  policy = data.aws_iam_policy_document.checker_logs.json
}

data "aws_iam_policy_document" "checker_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.checker.arn}:*"]
  }
}

resource "aws_iam_role_policy_attachment" "checker_metrics" {
  role       = aws_iam_role.checker.name
  policy_arn = aws_iam_policy.checker_metrics.arn
}

resource "aws_iam_policy" "checker_metrics" {
  name   = "trade-tariff-uptime-checker-metrics-${var.environment}"
  policy = data.aws_iam_policy_document.checker_metrics.json
}

data "aws_iam_policy_document" "checker_metrics" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["TradeTariff/Uptime"]
    }
  }
}

resource "aws_cloudwatch_log_group" "checker" {
  name              = "/aws/lambda/trade-tariff-uptime-checker-${var.environment}"
  retention_in_days = 14
}

resource "aws_lambda_function" "checker" {
  function_name    = "trade-tariff-uptime-checker-${var.environment}"
  filename         = data.archive_file.checker.output_path
  source_code_hash = data.archive_file.checker.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "ruby3.4"
  role             = aws_iam_role.checker.arn
  memory_size      = 256
  timeout          = 60

  environment {
    variables = {
      MONITORED_URLS = jsonencode([
        for name, url in var.monitored_urls : { name = name, url = url }
      ])
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.checker.name
  }
}

resource "aws_cloudwatch_event_rule" "checker" {
  name                = "trade-tariff-uptime-checker-${var.environment}"
  description         = "Triggers uptime checker Lambda every minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "checker" {
  rule = aws_cloudwatch_event_rule.checker.name
  arn  = aws_lambda_function.checker.arn
}

resource "aws_lambda_permission" "checker_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeUptimeChecker"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.checker.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.checker.arn
}

# ---------------------------------------------------------------------------
# CloudWatch alarms — one per endpoint
# Fires after failure_threshold consecutive 1-minute check failures.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "uptime" {
  for_each = var.monitored_urls

  alarm_name          = "uptime-${each.key}-${var.environment}"
  alarm_description   = "Uptime check failed for ${each.value}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.failure_threshold
  datapoints_to_alarm = var.failure_threshold
  metric_name         = "Availability"
  namespace           = "TradeTariff/Uptime"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    Endpoint = each.key
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# SNS topic — fan-out between alarms and the PagerDuty Lambda
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "trade-tariff-uptime-alerts-${var.environment}"
}

resource "aws_sns_topic_subscription" "pagerduty" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.pagerduty.arn
}

# ---------------------------------------------------------------------------
# Lambda: PagerDuty forwarder
# Translates CloudWatch Alarm SNS messages into PagerDuty Events API v2
# trigger/resolve calls. Skips silently when routing key is not yet set.
# ---------------------------------------------------------------------------

data "archive_file" "pagerduty" {
  type        = "zip"
  source_dir  = "${path.root}/../lambda/pagerduty"
  output_path = "${path.root}/../lambda/pagerduty.zip"
}

resource "aws_iam_role" "pagerduty" {
  name               = "trade-tariff-uptime-pagerduty-${var.environment}"
  path               = "/service-role/"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "pagerduty_logs" {
  role       = aws_iam_role.pagerduty.name
  policy_arn = aws_iam_policy.pagerduty_logs.arn
}

resource "aws_iam_policy" "pagerduty_logs" {
  name   = "trade-tariff-uptime-pagerduty-logs-${var.environment}"
  policy = data.aws_iam_policy_document.pagerduty_logs.json
}

data "aws_iam_policy_document" "pagerduty_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.pagerduty.arn}:*"]
  }
}

resource "aws_cloudwatch_log_group" "pagerduty" {
  name              = "/aws/lambda/trade-tariff-uptime-pagerduty-${var.environment}"
  retention_in_days = 14
}

resource "aws_lambda_function" "pagerduty" {
  function_name    = "trade-tariff-uptime-pagerduty-${var.environment}"
  filename         = data.archive_file.pagerduty.output_path
  source_code_hash = data.archive_file.pagerduty.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "ruby3.4"
  role             = aws_iam_role.pagerduty.arn
  memory_size      = 128
  timeout          = 30

  environment {
    variables = {
      PAGERDUTY_ROUTING_KEY = lookup(local.pagerduty_secret_map, "routing_key", "")
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.pagerduty.name
  }
}

resource "aws_lambda_permission" "pagerduty_sns" {
  statement_id  = "AllowSNSInvokeUptimePagerduty"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pagerduty.arn
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# ---------------------------------------------------------------------------
# Secret: PagerDuty routing key
# Populate after first apply:
#   aws secretsmanager put-secret-value \
#     --secret-id trade-tariff-uptime-pagerduty-{environment} \
#     --secret-string '{"routing_key":"<your-integration-key>"}'
# ---------------------------------------------------------------------------

resource "aws_kms_key" "uptime_monitor" {
  description             = "KMS key for uptime monitor secrets"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_kms_alias" "uptime_monitor" {
  name          = "alias/uptime-monitor-${var.environment}"
  target_key_id = aws_kms_key.uptime_monitor.key_id
}

resource "aws_secretsmanager_secret" "pagerduty" {
  name                    = "trade-tariff-uptime-pagerduty-${var.environment}"
  kms_key_id              = aws_kms_key.uptime_monitor.arn
  recovery_window_in_days = 7
}

data "aws_secretsmanager_secret_version" "pagerduty" {
  secret_id  = aws_secretsmanager_secret.pagerduty.id
  depends_on = [aws_secretsmanager_secret.pagerduty]
}

# ---------------------------------------------------------------------------
# CloudWatch dashboard — availability and response time per endpoint
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "uptime" {
  dashboard_name = "trade-tariff-uptime-${var.environment}"

  dashboard_body = jsonencode({
    widgets = flatten([
      for name, url in var.monitored_urls : [
        {
          type   = "metric"
          width  = 12
          height = 6
          properties = {
            title   = "${name} — Availability"
            region  = var.region
            metrics = [["TradeTariff/Uptime", "Availability", "Endpoint", name]]
            period  = 60
            stat    = "Minimum"
            view    = "timeSeries"
            yAxis   = { left = { min = 0, max = 1 } }
            annotations = {
              horizontal = [{ value = 1, color = "#2ca02c", label = "Up" }]
            }
          }
        },
        {
          type   = "metric"
          width  = 12
          height = 6
          properties = {
            title   = "${name} — Response Time (ms)"
            region  = var.region
            metrics = [["TradeTariff/Uptime", "ResponseTime", "Endpoint", name]]
            period  = 60
            stat    = "Average"
            view    = "timeSeries"
            yAxis   = { left = { min = 0 } }
          }
        }
      ]
    ])
  })
}
