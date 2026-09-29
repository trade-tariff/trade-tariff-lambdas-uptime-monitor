# Trade Tariff uptime monitor

This Ruby service monitors Trade Tariff URLs and reports availability and response
time to CloudWatch. EventBridge invokes the checker Lambda every minute.
CloudWatch alarms send sustained failures through SNS to a second Lambda, which
sends trigger and resolve events to PagerDuty.

## Develop and check changes

Use Ruby and Bundler. The deployed runtime is defined in
[serverless.yml](serverless.yml); dependency versions are in [Gemfile.lock](Gemfile.lock).

From the repository root:

```sh
bundle install
bundle exec rspec
```

The checker is in [lambda/checker/](lambda/checker/), the PagerDuty integration
is in [lambda/pagerduty/](lambda/pagerduty/), and tests are in [spec/](spec/).
Do not invoke a live handler to test documentation: it can publish metrics or
send alerts.

## Configure monitored URLs

Edit the stage-specific `MONITORED_URLS` map in
[.github/bin/deploy](.github/bin/deploy). Add the corresponding alarm and dashboard
configuration in [serverless.yml](serverless.yml). These settings are not managed
by Terraform files in this repository.

Review changes to monitored URLs, failure thresholds and recipients with the
service owner before deployment. A bad configuration can page the on-call team.

## Configure secrets

The deploy script passes `PAGERDUTY_ROUTING_KEY` and `WAF_BYPASS_TOKEN` to the
Lambda environment. Supply them through the approved deployment secret mechanism,
not tracked files or shell commands containing literal secret values.

Without a PagerDuty routing key, the notifier cannot send events. Without the WAF
token, protected endpoints can reject probes with HTTP 403. The checker sends the
WAF token in a request header and does not forward it to another host on redirect.
See [deployment workflows](.github/workflows/) for secret injection.

## Deployment

The [Makefile](Makefile) calls the Serverless deployment script for development,
staging or production. Non-main pushes can deploy to shared development; main
pushes deploy staging and production. There is no `make plan` target.

Deployments need authorised AWS access and approval for the target environment.
Changing a README does not require a manual deployment or a live probe.

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the fork workflow, checks and private
security reporting.

## Licence

The code and associated documentation use the [MIT licence](LICENCE.md), with
Crown copyright (HM Revenue & Customs). Dependencies retain their own licences.
