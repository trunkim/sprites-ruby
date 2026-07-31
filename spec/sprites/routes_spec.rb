# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Routes do
  let(:identifier) { "name/with space?#%" }
  let(:encoded) { "name%2Fwith%20space%3F%23%25" }

  it "encodes every dynamic resource identifier as one path segment" do
    expect(described_class.sprite(identifier)).to eq("/v1/sprites/#{encoded}")
    expect(described_class.exec(identifier)).to eq("/v1/sprites/#{encoded}/exec")
    expect(described_class.session(identifier, identifier))
      .to eq("/v1/sprites/#{encoded}/exec/#{encoded}")
    expect(described_class.session_kill(identifier, identifier))
      .to eq("/v1/sprites/#{encoded}/exec/#{encoded}/kill")

    expect(described_class.checkpoint_create(identifier))
      .to eq("/v1/sprites/#{encoded}/checkpoint")
    expect(described_class.checkpoint(identifier, identifier))
      .to eq("/v1/sprites/#{encoded}/checkpoints/#{encoded}")
    expect(described_class.checkpoint_restore(identifier, identifier))
      .to eq("/v1/sprites/#{encoded}/checkpoints/#{encoded}/restore")

    expect(described_class.service(identifier, identifier))
      .to eq("/v1/sprites/#{encoded}/services/#{encoded}")
    expect(described_class.service_action(identifier, identifier, "restart"))
      .to eq("/v1/sprites/#{encoded}/services/#{encoded}/restart")
    expect(described_class.organization_tokens(identifier))
      .to eq("/v1/organizations/#{encoded}/tokens")
  end

  it "builds HTTP and WebSocket URIs without treating query values as path data" do
    http = described_class.uri(
      "https://api.example.test///",
      described_class.session_kill(identifier, identifier),
      params: { signal: "TERM/HUP", timeout: "5 s" }
    )
    websocket = described_class.websocket_uri(
      "https://api.example.test/",
      described_class.control(identifier)
    )

    expect(http.to_s).to eq(
      "https://api.example.test/v1/sprites/#{encoded}/exec/#{encoded}/kill?" \
      "signal=TERM%2FHUP&timeout=5+s"
    )
    expect(websocket.to_s).to eq("wss://api.example.test/v1/sprites/#{encoded}/control")
  end
end
