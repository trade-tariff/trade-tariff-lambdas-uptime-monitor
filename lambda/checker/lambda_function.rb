require 'json'
require 'net/http'
require 'uri'
require 'aws-sdk-cloudwatch'

CLOUDWATCH_NAMESPACE = 'TradeTariff/Uptime'

# Net::HTTP does not follow redirects, so we follow them here. The limit exists
# so a redirect cycle fails the check instead of hanging until the Lambda times
# out.
MAX_REDIRECTS = 5

# Identifies the probe in the target's access logs.
USER_AGENT = 'trade-tariff-uptime-monitor (+https://github.com/trade-tariff/trade-tariff-uptime-monitor)'

# The monitored pages sit behind AWS Bot Control, which answers 403 to any
# client that does not look like a browser. This is the header the WAF's
# allow-e2e-tests rule already matches on, and it runs at a lower priority than
# Bot Control, so a correct token short circuits the block. The value is a
# shared secret, not the User-Agent, because a User-Agent is public and an
# allow rule matching one would be a bypass for anybody.
WAF_BYPASS_HEADER = 'x-waf-bypass'

def lambda_handler(event:, context:)
  endpoints = JSON.parse(ENV.fetch('MONITORED_URLS'))
  cloudwatch = Aws::CloudWatch::Client.new

  endpoints.each do |endpoint|
    name = endpoint.fetch('name')
    url  = endpoint.fetch('url')

    available, response_time_ms = probe(url)

    cloudwatch.put_metric_data(
      namespace: CLOUDWATCH_NAMESPACE,
      metric_data: [
        {
          metric_name: 'Availability',
          dimensions: [{ name: 'Endpoint', value: name }],
          value: available ? 1.0 : 0.0,
          unit: 'Count'
        },
        {
          metric_name: 'ResponseTime',
          dimensions: [{ name: 'Endpoint', value: name }],
          value: response_time_ms.to_f,
          unit: 'Milliseconds'
        }
      ]
    )

    puts "#{name}: available=#{available} response_time=#{response_time_ms}ms"
  end
end

# An endpoint is available only when it finally answers 2xx. Anything else (404,
# 403, a redirect to an error page, a redirect cycle) is a user visible failure
# even though the server is technically responding.
def probe(url)
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  response   = get_following_redirects(url)
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

  status    = response.code.to_i
  available = status >= 200 && status < 300

  puts "Probe for #{url} finished with #{status}" unless available

  [available, elapsed_ms]
rescue => e
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  puts "Probe failed for #{url}: #{e.class} #{e.message}"
  [false, elapsed_ms]
end

def get_following_redirects(url)
  uri = URI.parse(url)
  monitored_host = uri.host

  MAX_REDIRECTS.times do
    response = get(uri, monitored_host)
    return response unless response.is_a?(Net::HTTPRedirection)

    location = response['location']
    return response if location.nil? || location.empty?

    uri = URI.join(uri, location)
  end

  raise "Exceeded #{MAX_REDIRECTS} redirects starting from #{url}"
end

def get(uri, monitored_host)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = uri.scheme == 'https'
  http.open_timeout = 10
  http.read_timeout = 15

  headers = { 'User-Agent' => USER_AGENT }

  # Send the token only to the host we were told to monitor. A redirect can
  # point anywhere, and this secret must not follow it off to a third party.
  token = ENV.fetch('WAF_BYPASS_TOKEN', '')
  headers[WAF_BYPASS_HEADER] = token if !token.empty? && uri.host == monitored_host

  http.get(uri.request_uri, headers)
end
