# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Management do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }

  describe "#create_sprite" do
    it "creates a sprite" do
      stub_request(:post, "http://localhost:8080/v1/sprites")
        .with(
          headers: { "Authorization" => "Bearer test-token", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 201,
          body: JSON.generate({ name: "my-sprite" }),
          headers: { "Content-Type" => "application/json" }
        )

      sprite = client.create_sprite("my-sprite")
      expect(sprite).to be_a(Sprites::Sprite)
      expect(sprite.name).to eq("my-sprite")
      expect(sprite.status).to eq("created")
    end

    it "raises APIError on failure" do
      stub_request(:post, "http://localhost:8080/v1/sprites")
        .to_return(
          status: 429,
          body: JSON.generate({ error: "sprite_creation_rate_limited", message: "rate limited" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.create_sprite("my-sprite") }.to raise_error(Sprites::APIError)
    end
  end

  describe "#get_sprite" do
    it "retrieves a sprite" do
      stub_request(:get, "http://localhost:8080/v1/sprites/my-sprite")
        .to_return(
          status: 200,
          body: JSON.generate({
            id: "sp-123",
            name: "my-sprite",
            organization: "personal",
            status: "running"
          }),
          headers: { "Content-Type" => "application/json" }
        )

      sprite = client.get_sprite("my-sprite")
      expect(sprite.name).to eq("my-sprite")
      expect(sprite.status).to eq("running")
      expect(sprite.id).to eq("sp-123")
    end

    it "raises error for not found" do
      stub_request(:get, "http://localhost:8080/v1/sprites/missing")
        .to_return(status: 404)

      expect { client.get_sprite("missing") }.to raise_error(Sprites::Error, /not found/)
    end
  end

  describe "#list_sprites" do
    it "lists sprites with pagination" do
      stub_request(:get, "http://localhost:8080/v1/sprites?max_results=100")
        .to_return(
          status: 200,
          body: JSON.generate({
            sprites: [
              { name: "sprite-1", status: "running" },
              { name: "sprite-2", status: "cold" }
            ],
            has_more: false
          }),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.list_sprites
      expect(result[:sprites].length).to eq(2)
      expect(result[:sprites][0].name).to eq("sprite-1")
      expect(result[:has_more]).to be false
    end
  end

  describe "#delete_sprite" do
    it "deletes a sprite" do
      stub_request(:delete, "http://localhost:8080/v1/sprites/my-sprite")
        .to_return(status: 204)

      expect { client.delete_sprite("my-sprite") }.not_to raise_error
    end
  end

  describe "#upgrade_sprite" do
    it "upgrades a sprite" do
      stub_request(:post, "http://localhost:8080/v1/sprites/my-sprite/upgrade")
        .to_return(status: 200)

      expect { client.upgrade_sprite("my-sprite") }.not_to raise_error
    end
  end
end
