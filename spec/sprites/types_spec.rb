# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::SpriteConfig do
  describe ".from_hash" do
    it "creates from hash" do
      config = described_class.from_hash({ "ram_mb" => 512, "cpus" => 2, "region" => "iad", "storage_gb" => 10 })
      expect(config.ram_mb).to eq(512)
      expect(config.cpus).to eq(2)
      expect(config.region).to eq("iad")
      expect(config.storage_gb).to eq(10)
    end

    it "returns nil for nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe "#to_h" do
    it "only includes non-nil values" do
      config = described_class.new(ram_mb: 256)
      expect(config.to_h).to eq({ ram_mb: 256 })
    end
  end
end

RSpec.describe Sprites::Session do
  describe ".from_hash" do
    it "creates from hash" do
      session = described_class.from_hash({
        "id" => "abc-123",
        "command" => "bash",
        "is_active" => true,
        "tty" => true
      })
      expect(session.id).to eq("abc-123")
      expect(session.command).to eq("bash")
      expect(session.is_active).to be true
      expect(session.tty).to be true
    end
  end

  describe "#active?" do
    it "returns true for recently active session" do
      session = described_class.new(
        is_active: true,
        last_activity: Time.now
      )
      expect(session.active?).to be true
    end

    it "returns false for stale session" do
      session = described_class.new(
        is_active: true,
        last_activity: Time.now - 600
      )
      expect(session.active?).to be false
    end

    it "returns false for inactive session" do
      session = described_class.new(is_active: false)
      expect(session.active?).to be false
    end
  end
end

RSpec.describe Sprites::NetworkPolicy do
  describe ".from_hash" do
    it "creates from hash with rules" do
      policy = described_class.from_hash({
        "rules" => [
          { "domain" => "*.example.com", "action" => "allow" },
          { "domain" => "evil.com", "action" => "deny" }
        ]
      })
      expect(policy.rules.length).to eq(2)
      expect(policy.rules[0].domain).to eq("*.example.com")
      expect(policy.rules[0].action).to eq("allow")
    end
  end

  describe "#to_h" do
    it "serializes to hash" do
      policy = described_class.new(rules: [
        Sprites::NetworkPolicyRule.new(domain: "example.com", action: "allow")
      ])
      h = policy.to_h
      expect(h[:rules]).to eq([{ domain: "example.com", action: "allow" }])
    end
  end
end

RSpec.describe Sprites::SpriteInfo do
  describe ".from_hash" do
    it "creates from full hash" do
      info = described_class.from_hash({
        "id" => "sp-123",
        "name" => "test-sprite",
        "organization" => "personal",
        "status" => "running",
        "created_at" => "2024-01-01T00:00:00Z"
      })
      expect(info.id).to eq("sp-123")
      expect(info.name).to eq("test-sprite")
      expect(info.status).to eq("running")
      expect(info.created_at).to be_a(Time)
    end
  end
end

RSpec.describe Sprites::ServiceRequest do
  describe "#to_h" do
    it "serializes service environment, directory, and http port" do
      request = described_class.new(
        cmd: "bin/rails",
        args: %w[server -b 0.0.0.0],
        env: { "RAILS_ENV" => "development" },
        dir: "/workspace/app",
        http_port: 3000
      )

      expect(request.to_h).to eq({
        cmd: "bin/rails",
        args: %w[server -b 0.0.0.0],
        env: { "RAILS_ENV" => "development" },
        dir: "/workspace/app",
        http_port: 3000
      })
    end
  end
end

RSpec.describe Sprites::ServiceWithState do
  describe ".from_hash" do
    it "parses service environment and directory" do
      service = described_class.from_hash({
        "name" => "web",
        "cmd" => "bin/rails",
        "args" => %w[server],
        "env" => { "RAILS_ENV" => "development" },
        "dir" => "/workspace/app",
        "http_port" => 3000,
        "state" => { "status" => "running" }
      })

      expect(service.env).to eq({ "RAILS_ENV" => "development" })
      expect(service.dir).to eq("/workspace/app")
      expect(service.state.status).to eq("running")
    end
  end
end
