# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Management do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }

  describe "#create_sprite" do
    it "creates a sprite with wait_for_capacity when explicitly requested" do
      stub_request(:post, "http://localhost:8080/v1/sprites")
        .with(
          headers: { "Authorization" => "Bearer test-token", "Content-Type" => "application/json" },
          body: hash_including("name" => "my-sprite", "wait_for_capacity" => true)
        )
        .to_return(
          status: 201,
          body: JSON.generate({ name: "my-sprite" }),
          headers: { "Content-Type" => "application/json" }
        )

      sprite = client.create_sprite("my-sprite", wait_for_capacity: true)
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

    it "raises typed APIError for not found" do
      stub_request(:get, "http://localhost:8080/v1/sprites/missing")
        .to_return(
          status: 404,
          body: JSON.generate({ error: "not_found", message: "sprite not found: missing" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.get_sprite("missing") }.to raise_error(Sprites::APIError) { |err|
        expect(err.status_code).to eq(404)
      }
    end
  end

  describe "#list_sprites" do
    it "lists sprites with pagination" do
      stub_request(:get, "http://localhost:8080/v1/sprites?max_results=50")
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

  describe "#list_all_sprites_result" do
    it "follows continuation_token across pages until has_more is false" do
      stub_request(:get, "http://localhost:8080/v1/sprites?max_results=50")
        .to_return(
          status: 200,
          body: JSON.generate({
            sprites: [ { name: "sprite-1", status: "running" } ],
            has_more: true,
            next_continuation_token: "tok-page-2"
          }),
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, "http://localhost:8080/v1/sprites?max_results=50&continuation_token=tok-page-2")
        .to_return(
          status: 200,
          body: JSON.generate({
            sprites: [ { name: "sprite-2", status: "cold" } ],
            has_more: false
          }),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.list_all_sprites_result
      expect(result.sprites.map(&:name)).to eq(%w[sprite-1 sprite-2])
    end

    it "stops when has_more is true but next_continuation_token is missing" do
      stub_request(:get, "http://localhost:8080/v1/sprites?max_results=50")
        .to_return(
          status: 200,
          body: JSON.generate({
            sprites: [ { name: "sprite-1", status: "running" } ],
            has_more: true
          }),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.list_all_sprites_result
      expect(result.sprites.map(&:name)).to eq(%w[sprite-1])
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
