# frozen_string_literal: true

RSpec.describe 'checker lambda' do
  subject(:checker) { load_lambda('lambda/checker/lambda_function.rb') }

  let(:url) { 'https://www.example.com/find_commodity' }

  describe '#probe' do
    it 'reports available for a 200' do
      stub_request(:get, url).to_return(status: 200)

      available, = checker.probe(url)

      expect(available).to be(true)
    end

    it 'reports unavailable for a 404' do
      stub_request(:get, url).to_return(status: 404)

      available, = checker.probe(url)

      expect(available).to be(false)
    end

    it 'reports unavailable for a 403' do
      stub_request(:get, url).to_return(status: 403)

      available, = checker.probe(url)

      expect(available).to be(false)
    end

    it 'reports unavailable for a 500' do
      stub_request(:get, url).to_return(status: 500)

      available, = checker.probe(url)

      expect(available).to be(false)
    end

    it 'follows a redirect and reports available when it lands on a 200' do
      stub_request(:get, url).to_return(status: 301, headers: { 'Location' => 'https://www.example.com/commodities' })
      final = stub_request(:get, 'https://www.example.com/commodities').to_return(status: 200)

      available, = checker.probe(url)

      expect(available).to be(true)
      expect(final).to have_been_requested
    end

    it 'follows a relative redirect' do
      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => '/commodities' })
      final = stub_request(:get, 'https://www.example.com/commodities').to_return(status: 200)

      available, = checker.probe(url)

      expect(available).to be(true)
      expect(final).to have_been_requested
    end

    it 'reports unavailable when a redirect lands on an error page' do
      stub_request(:get, url).to_return(status: 301, headers: { 'Location' => 'https://www.example.com/gone' })
      stub_request(:get, 'https://www.example.com/gone').to_return(status: 404)

      available, = checker.probe(url)

      expect(available).to be(false)
    end

    it 'reports unavailable rather than looping forever on a redirect cycle' do
      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => url })

      available, = checker.probe(url)

      expect(available).to be(false)
    end

    it 'reports unavailable when the connection fails' do
      stub_request(:get, url).to_timeout

      available, = checker.probe(url)

      expect(available).to be(false)
    end

    it 'reports unavailable when the URL cannot be parsed' do
      available, elapsed_ms = checker.probe('http://[not a url')

      expect(available).to be(false)
      expect(elapsed_ms).to be_a(Integer)
    end

    it 'identifies itself with a User-Agent so the probe is attributable in access logs' do
      request = stub_request(:get, url)
                .with(headers: { 'User-Agent' => checker::USER_AGENT })
                .to_return(status: 200)

      checker.probe(url)

      expect(request).to have_been_requested
    end

    context 'when WAF_BYPASS_TOKEN is set' do
      before { ENV['WAF_BYPASS_TOKEN'] = 'a-shared-secret' }
      after  { ENV.delete('WAF_BYPASS_TOKEN') }

      it 'sends the bypass header so Bot Control does not answer 403' do
        request = stub_request(:get, url)
                  .with(headers: { checker::WAF_BYPASS_HEADER => 'a-shared-secret' })
                  .to_return(status: 200)

        checker.probe(url)

        expect(request).to have_been_requested
      end

      it 'keeps sending the bypass header across a redirect on the monitored host' do
        stub_request(:get, url).to_return(status: 302, headers: { 'Location' => '/commodities' })
        final = stub_request(:get, 'https://www.example.com/commodities')
                .with(headers: { checker::WAF_BYPASS_HEADER => 'a-shared-secret' })
                .to_return(status: 200)

        checker.probe(url)

        expect(final).to have_been_requested
      end

      it 'withholds the bypass header from a redirect to another host' do
        stub_request(:get, url).to_return(status: 302, headers: { 'Location' => 'https://elsewhere.example.org/' })
        final = stub_request(:get, 'https://elsewhere.example.org/').to_return(status: 200)

        checker.probe(url)

        expect(final).to have_been_requested
        expect(WebMock).not_to have_requested(:get, 'https://elsewhere.example.org/')
          .with(headers: { checker::WAF_BYPASS_HEADER => 'a-shared-secret' })
      end
    end

    it 'omits the bypass header when no token is configured' do
      request = stub_request(:get, url).to_return(status: 200)

      checker.probe(url)

      expect(request).to have_been_requested
      expect(WebMock).not_to have_requested(:get, url)
        .with { |req| req.headers.key?('X-Waf-Bypass') }
    end
  end

  describe '#lambda_handler' do
    let(:cloudwatch) { instance_double(Aws::CloudWatch::Client, put_metric_data: nil) }

    before do
      allow(Aws::CloudWatch::Client).to receive(:new).and_return(cloudwatch)
      ENV['MONITORED_URLS'] = [{ 'name' => 'find-commodity', 'url' => url }].to_json
    end

    after { ENV.delete('MONITORED_URLS') }

    it 'publishes Availability 0.0 for a non 2xx response' do
      stub_request(:get, url).to_return(status: 404)

      checker.lambda_handler(event: {}, context: nil)

      expect(cloudwatch).to have_received(:put_metric_data) do |args|
        availability = args[:metric_data].find { |datum| datum[:metric_name] == 'Availability' }
        expect(availability[:value]).to eq(0.0)
      end
    end

    it 'publishes Availability 1.0 for a 200 response' do
      stub_request(:get, url).to_return(status: 200)

      checker.lambda_handler(event: {}, context: nil)

      expect(cloudwatch).to have_received(:put_metric_data) do |args|
        availability = args[:metric_data].find { |datum| datum[:metric_name] == 'Availability' }
        expect(availability[:value]).to eq(1.0)
      end
    end
  end
end
