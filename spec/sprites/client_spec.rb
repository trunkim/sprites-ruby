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

    it "fences owned HTTP requests and reports all local connections closed" do
      client = described_class.new(token, base_url: "http://localhost:8080")
      client.close

      expect(client.open_connection_count).to eq(0)
      uri = URI("http://localhost:8080/v1/sprites")
      expect { client.request(uri, Net::HTTP::Get.new(uri)) }
        .to raise_error(Sprites::Error, "client is closed")
    end
  end

  describe "#sprite" do
    it "returns a handle without probing control" do
      client = described_class.new(token, base_url: "http://localhost:8080")
      expect(client).not_to receive(:get_or_create_pool)
      sprite = client.sprite("my-sprite")
      expect(sprite.name).to eq("my-sprite")
      expect(sprite.supports_control?).to be false
    end
  end

  describe "http_client injection" do
    it "uses the injected transport for REST calls" do
      response = Struct.new(:code, :body) do
        def [](_key) = nil
      end.new("200", JSON.generate({ name: "my-sprite", status: "cold" }))

      fake = Class.new do
        attr_reader :requests

        def initialize(response)
          @response = response
          @requests = []
        end

        def request(req)
          @requests << req
          @response
        end
      end.new(response)

      client = described_class.new(token, base_url: "http://localhost:8080", http_client: fake)
      sprite = client.get_sprite("my-sprite")
      expect(sprite.name).to eq("my-sprite")
      expect(fake.requests.first).to be_a(Net::HTTP::Get)
    end

    it "serializes concurrent requests on one injected transport" do
      response = Struct.new(:code, :body) do
        def [](_key) = nil
      end.new("200", "{}")
      fake = Class.new do
        attr_reader :overlapped

        def initialize(response)
          @response = response
          @mutex = Mutex.new
          @active = 0
          @overlapped = false
        end

        def request(_req)
          @mutex.synchronize do
            @active += 1
            @overlapped = true if @active > 1
          end
          sleep 0.02
          @response
        ensure
          @mutex.synchronize { @active -= 1 }
        end
      end.new(response)
      client = described_class.new(token, base_url: "http://localhost:8080", http_client: fake)
      uri = URI("http://localhost:8080/v1/sprites")
      start = Queue.new

      threads = 2.times.map do
        Thread.new do
          start.pop
          client.request(uri, Net::HTTP::Get.new(uri))
        end
      end
      2.times { start << true }
      threads.each(&:join)

      expect(fake.overlapped).to be false
    end
  end
end
