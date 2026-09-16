# frozen_string_literal: true

require 'webmock/rspec'

# The specs name Aws::CloudWatch::Client in a before hook, which runs before the
# lazy subject loads a Lambda entrypoint. Requiring the SDK here makes the
# constant available whatever order the examples run in. Without this, an
# example that loads an entrypoint first defines Aws as a side effect and hides
# the problem, so the suite passes or fails by seed.
require 'aws-sdk-cloudwatch'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end

# The Lambda entrypoints define top level methods, so requiring one would leak
# its methods into the spec process. Evaluate each into its own anonymous module
# instead, which also keeps separate entrypoints from colliding with each other.
def load_lambda(relative_path)
  source = File.read(File.expand_path("../#{relative_path}", __dir__))
  namespace = Module.new
  namespace.module_eval(source, relative_path)
  namespace.extend(namespace)
  namespace
end
