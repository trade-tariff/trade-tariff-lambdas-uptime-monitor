variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "monitored_urls" {
  description = "Map of endpoint name to URL. Each entry gets its own alarm, metric, and dashboard widget."
  type        = map(string)
}

variable "failure_threshold" {
  description = "Number of consecutive 1-minute failures before a PagerDuty alert fires"
  type        = number
  default     = 3
}
