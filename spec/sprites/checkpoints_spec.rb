# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Checkpoints do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }

  describe "#list_checkpoints" do
    it "returns checkpoints" do
      stub_request(:get, "http://localhost:8080/v1/sprites/my-sprite/checkpoints")
        .to_return(
          status: 200,
          body: JSON.generate([
            {
              "id" => "v2",
              "create_time" => "2026-04-24T17:40:17Z",
              "source_id" => "src-1",
              "comment" => "before deploy",
              "health" => "healthy",
              "is_auto" => false
            },
            { "id" => "v1", "create_time" => "2026-04-24T17:25:27Z", "comment" => nil, "is_auto" => false },
            { "id" => "v0", "create_time" => "2026-04-24T17:25:27Z", "comment" => nil, "is_auto" => true }
          ]),
          headers: { "Content-Type" => "application/json" }
        )

      checkpoints = client.list_checkpoints("my-sprite")
      expect(checkpoints.size).to eq(3)
      expect(checkpoints[0].id).to eq("v2")
      expect(checkpoints[0].comment).to eq("before deploy")
      expect(checkpoints[0].source_id).to eq("src-1")
      expect(checkpoints[0].health).to eq("healthy")
      expect(checkpoints[0]).to be_healthy
      expect(checkpoints[2].is_auto).to be true
    end

    it "filters auto checkpoints when requested" do
      stub_request(:get, "http://localhost:8080/v1/sprites/my-sprite/checkpoints?includeAuto=true")
        .to_return(
          status: 200,
          body: JSON.generate([]),
          headers: { "Content-Type" => "application/json" }
        )

      checkpoints = client.list_checkpoints("my-sprite", include_auto: true)
      expect(checkpoints).to eq([])
    end
  end

  describe "#get_checkpoint" do
    it "returns a single checkpoint" do
      stub_request(:get, "http://localhost:8080/v1/sprites/my-sprite/checkpoints/v1")
        .to_return(
          status: 200,
          body: JSON.generate({ "id" => "v1", "create_time" => "2026-04-24T17:25:27Z", "comment" => "test" }),
          headers: { "Content-Type" => "application/json" }
        )

      cp = client.get_checkpoint("my-sprite", "v1")
      expect(cp.id).to eq("v1")
      expect(cp.comment).to eq("test")
    end
  end

  describe "#delete_checkpoint" do
    it "deletes a checkpoint" do
      stub_request(:delete, "http://localhost:8080/v1/sprites/my-sprite/checkpoints/v1")
        .to_return(status: 204)

      expect { client.delete_checkpoint("my-sprite", "v1") }.not_to raise_error
    end

    it "raises on 404" do
      stub_request(:delete, "http://localhost:8080/v1/sprites/my-sprite/checkpoints/missing")
        .to_return(
          status: 404,
          body: JSON.generate({ "error" => "not_found", "message" => "checkpoint not found" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.delete_checkpoint("my-sprite", "missing") }.to raise_error(Sprites::APIError)
    end
  end
end
