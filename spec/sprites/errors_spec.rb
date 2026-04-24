# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::APIError do
  describe ".parse" do
    it "returns nil for successful responses" do
      resp = double("response", code: "200", :[] => nil)
      expect(described_class.parse(resp, "")).to be_nil
    end

    it "parses JSON error body" do
      resp = double("response", code: "429", :[] => nil)
      body = JSON.generate({
        error: "sprite_creation_rate_limited",
        message: "Rate limit exceeded",
        limit: 10,
        retry_after_seconds: 30
      })

      err = described_class.parse(resp, body)
      expect(err).to be_a(described_class)
      expect(err.error_code).to eq("sprite_creation_rate_limited")
      expect(err.message).to eq("Rate limit exceeded")
      expect(err.status_code).to eq(429)
      expect(err.rate_limit_error?).to be true
      expect(err.creation_rate_limited?).to be true
      expect(err.get_retry_after_seconds).to eq(30)
    end

    it "handles non-JSON body" do
      resp = double("response", code: "500", :[] => nil)
      err = described_class.parse(resp, "Internal Server Error")

      expect(err.status_code).to eq(500)
      expect(err.message).to eq("Internal Server Error")
    end

    it "parses rate limit headers" do
      resp = double("response", code: "429")
      allow(resp).to receive(:[]).with("Retry-After").and_return("60")
      allow(resp).to receive(:[]).with("X-RateLimit-Limit").and_return("100")
      allow(resp).to receive(:[]).with("X-RateLimit-Remaining").and_return("0")
      allow(resp).to receive(:[]).with("X-RateLimit-Reset").and_return("1700000000")
      allow(resp).to receive(:[]).with("Sprite-Version").and_return(nil)

      err = described_class.parse(resp, "{}")
      expect(err.retry_after_header).to eq(60)
      expect(err.rate_limit_limit).to eq(100)
      expect(err.rate_limit_remaining).to eq(0)
      expect(err.rate_limit_reset).to eq(1700000000)
    end
  end

  describe "#concurrent_limit_exceeded?" do
    it "returns true for concurrent limit errors" do
      err = described_class.new(error_code: "concurrent_sprite_limit_exceeded")
      expect(err.concurrent_limit_exceeded?).to be true
    end

    it "returns false for other errors" do
      err = described_class.new(error_code: "other_error")
      expect(err.concurrent_limit_exceeded?).to be false
    end
  end
end

RSpec.describe Sprites::ExitError do
  it "has an exit code" do
    err = described_class.new(42)
    expect(err.exit_code).to eq(42)
    expect(err.message).to eq("exit status 42")
  end
end

RSpec.describe Sprites do
  describe ".api_error?" do
    it "returns the error for APIError" do
      err = Sprites::APIError.new(status_code: 500)
      expect(Sprites.api_error?(err)).to eq(err)
    end

    it "returns nil for non-APIError" do
      expect(Sprites.api_error?(StandardError.new)).to be_nil
    end
  end

  describe ".rate_limit_error?" do
    it "returns the error for rate limit errors" do
      err = Sprites::APIError.new(status_code: 429)
      expect(Sprites.rate_limit_error?(err)).to eq(err)
    end

    it "returns nil for non-rate-limit errors" do
      err = Sprites::APIError.new(status_code: 500)
      expect(Sprites.rate_limit_error?(err)).to be_nil
    end
  end
end
