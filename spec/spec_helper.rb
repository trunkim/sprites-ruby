# frozen_string_literal: true

require "sprites"
require "webmock/rspec"
require "json"

RSpec.configure do |config|
  config.filter_run_excluding live: true unless ENV["SPRITES_LIVE_API"] == "1"

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
