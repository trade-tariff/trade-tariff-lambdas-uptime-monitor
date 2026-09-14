# frozen_string_literal: true

require 'webmock/rspec'

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
