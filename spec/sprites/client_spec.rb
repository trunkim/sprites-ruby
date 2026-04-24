# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Client do
  let(:token) { "test-token" }

  describe "#initialize" do
    it "creates a client with default settings" do
      client = described_class.new(token)
      expect(client.token).to eq(token)
      expect(client.base_url).to eq("https://api.sprites.dev")
    end

    it "accepts a custom base_url" do
      client = described_class.new(token, base_url: "http://localhost:8080")
      expect(client.base_url).to eq("http://localhost:8080")
    end

    it "strips trailing slash from base_url" do
      client = described_class.new(token, base_url: "http://localhost:8080/")
      expect(client.base_url).to eq("http://localhost:8080")
    end

    it "returns empty sprite_version initially" do
      client = described_class.new(token)
      expect(client.sprite_version).to eq("")
    end
  end

  describe "#close" do
    it "closes without error" do
      client = described_class.new(token)
      expect { client.close }.not_to raise_error
    end
  end
end
