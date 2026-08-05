# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::ClientSignals do
  around do |example|
    original = tracked_env.to_h { |name| [ name, ENV.key?(name) ? ENV[name] : :missing ] }
    tracked_env.each { |name| ENV.delete(name) }
    described_class.reset_for_test!
    example.run
  ensure
    original.each do |name, value|
      value == :missing ? ENV.delete(name) : ENV[name] = value
    end
    described_class.reset_for_test!
  end

  def tracked_env
    (
      described_class::KNOWN_MARKERS.map { |(_, name, _, _)| name } +
        %w[FLY_INVOKED_BY AGENT CI GITHUB_ACTIONS SPRITES_CLIENT_SIGNALS]
    ).uniq
  end

  it "returns the official process attribution shape and a fresh header Hash" do
    headers = described_class.headers

    expect(headers.fetch("User-Agent")).to start_with("sprites-ruby/#{Sprites::VERSION} ")
    expect(headers.fetch("Fly-Client-Interactive")).to match(/\A(?:true|false)\z/)
    expect(headers.fetch("Fly-Client-Parent")).to match(/\A(?:node|python|shell|other)\z/)

    headers["User-Agent"] = "mutated"
    expect(described_class.headers.fetch("User-Agent")).not_to eq("mutated")
  end

  it "supports the official opt-out without dropping the SDK User-Agent" do
    ENV["SPRITES_CLIENT_SIGNALS"] = "disabled"

    expect(described_class.headers).to eq(
      "User-Agent" => "sprites-ruby/#{Sprites::VERSION}"
    )
  end

  it "detects a sanitized explicit invoker once for the process" do
    ENV["FLY_INVOKED_BY"] = "  Build-Agent  "

    first = described_class.headers
    ENV["FLY_INVOKED_BY"] = "changed-agent"
    second = described_class.headers

    expect(first).to include(
      "Fly-Client-Agent" => "build-agent",
      "Fly-Client-Agent-Source" => "env:FLY_INVOKED_BY"
    )
    expect(second).to eq(first)
  end

  it "rejects invalid explicit agent names and recognizes CI" do
    ENV["FLY_INVOKED_BY"] = "../../unsafe"
    ENV["CI"] = "0"

    expect(described_class.headers).not_to have_key("Fly-Client-Agent")
    expect(described_class.headers.fetch("Fly-Client-CI")).to eq("true")
  end

  it "merges bearer auth and lets request-specific headers take final precedence" do
    headers = described_class.auth_headers(
      "secret",
      "Content-Type" => "application/json",
      "Authorization" => "Bearer override"
    )

    expect(headers).to include(
      "Authorization" => "Bearer override",
      "Content-Type" => "application/json"
    )
  end

  it "uses the same privacy-safe parent buckets as the official client-signals package" do
    classify = ->(name) { described_class.send(:classify_parent_name, name) }

    expect(classify.call("/usr/bin/node")).to eq("node")
    expect(classify.call("python3")).to eq("python")
    expect(classify.call("zsh")).to eq("shell")
    expect(classify.call("ruby")).to eq("other")
  end
end
