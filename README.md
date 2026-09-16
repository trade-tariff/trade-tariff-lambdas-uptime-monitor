# trade-tariff-uptime-monitor

Monitors the availability and response time of OTT service URLs, alerting via PagerDuty on sustained failures.

An EventBridge rule triggers a checker Lambda every minute. It probes each configured URL and publishes two CloudWatch metrics per endpoint (`Availability` and `ResponseTime`) to the `TradeTariff/Uptime` namespace. CloudWatch alarms fire after three consecutive failures and forward to a PagerDuty Lambda via SNS, which calls the PagerDuty Events API v2. Alarms auto-resolve when the endpoint recovers. A CloudWatch dashboard provides a live view of availability and response time history per endpoint.

## Architecture

```
EventBridge (rate 1 min)
  └─> Checker Lambda
        └─> CloudWatch Metrics (TradeTariff/Uptime)
              └─> CloudWatch Alarm (3 consecutive failures)
                    └─> SNS Topic
                          └─> PagerDuty Lambda (Events API v2 trigger/resolve)
```

## Adding URLs to monitor

Edit `environments/<environment>.tfvars` and add an entry to `monitored_urls`:

```hcl
monitored_urls = {
  "find-commodity"    = "https://www.trade-tariff.service.gov.uk/find_commodity"
  "search-commodity"  = "https://www.trade-tariff.service.gov.uk/search"
}
```

Each entry automatically gets its own CloudWatch alarm, metric stream, and dashboard widget. Push to deploy.

## Configuring PagerDuty

After the first deploy, populate the routing key from your PagerDuty service's Events API v2 integration:

```sh
aws secretsmanager put-secret-value \
  --region eu-west-2 \
  --secret-id trade-tariff-uptime-pagerduty-<environment> \
  --secret-string '{"routing_key":"<your-integration-key>"}'
```

Then redeploy so Terraform picks up the new value and injects it into the Lambda environment. Until the key is set the Lambda skips PagerDuty calls silently — metrics and alarms still work.

## Getting past the WAF

The monitored pages sit behind CloudFront and AWS Bot Control, which answers 403
to any client that does not look like a browser. Without help, every probe of
production records `Availability = 0` and pages the on-call.

The checker therefore sends an `x-waf-bypass` header, taken from the
`WAF_BYPASS_TOKEN` environment variable. The WAF already has an
`allow-e2e-tests` rule that matches this header at a lower priority than Bot
Control, so a correct value short circuits the block. The deploy workflows read
the value from the `TF_VAR_WAF_E2E_SECRET_TOKEN` organisation secret, which is
the same secret the terraform repo feeds to that rule. There is one value, thus
the two cannot drift apart.

Two properties are deliberate. The token is a secret and not the User-Agent,
because a User-Agent is public and an allow rule matching one would be a bypass
for anybody. The probe also withholds the token from a redirect that leaves the
monitored host, so the secret cannot follow an open redirect to a third party.

`WAF_BYPASS_TOKEN` defaults to empty. A deploy without it is successful, the
probe omits the header, and production returns 403.

## Deployments

Deployments are triggered automatically via GitHub Actions:

| Event | Environment |
|---|---|
| Push to any non-`main` branch | Development |
| Push to `main` | Staging and Production |

To deploy manually, load AWS credentials for the target account and run:

```sh
make deploy-development
make deploy-staging
make deploy-production
```

You can also run `make plan STAGE=<environment>` to preview changes without applying them.
