# frozen_string_literal: true

require "spec_helper"

module AttributionFixtures
  class Response
    attr_reader :code, :body

    def initialize(code: "200", body: "{}")
      @code = code
      @body = body
    end

    def [](_name) = nil
  end

  class HTTP
    attr_reader :requests
    attr_accessor :read_timeout, :open_timeout, :write_timeout

    def initialize
      @requests = []
    end

    def request(request)
      @requests << request
      response = Response.new
      block_given? ? yield(response) : response
    end
  end

  class Stream
    def start = self
    def close = nil
    def connection_open? = false
  end

  class WebSocket
    def connect! = self
    def close = nil
    def closed? = false
    def read_message = nil
  end
end

RSpec.describe "authenticated transport attribution" do

  let(:http) { AttributionFixtures::HTTP.new }
  let(:client) do
    Sprites::Client.new(
      "transport-token",
      base_url: "https://example.test",
      http_client: http,
      disable_control: true
    )
  end

  after { client.close }

  def expect_attributed(headers)
    normalized = headers.to_h.transform_keys { |name| name.to_s.downcase }
                        .transform_values { |value| Array(value).first }
    expect(normalized.fetch("authorization")).to eq("Bearer transport-token")
    expect(normalized.fetch("user-agent")).to start_with("sprites-ruby/")
    expect(normalized.fetch("fly-client-interactive")).to match(/\A(?:true|false)\z/)
    expect(normalized.fetch("fly-client-parent")).to match(/\A(?:node|python|shell|other)\z/)
  end

  it "attributes buffered and block-streaming HTTP at the Client I/O shell" do
    uri = URI("https://example.test/v1/sprites/demo")
    client.request(uri, Net::HTTP::Get.new(uri))
    client.request_stream(uri, Net::HTTP::Get.new(uri)) { :consumed }

    expect(http.requests.size).to eq(2)
    http.requests.each { |request| expect_attributed(request.to_hash) }
  end

  it "attributes long-lived NDJSON before handing the request to HTTPStreamResponse" do
    captured = nil
    allow(Sprites::HTTPStreamResponse).to receive(:new) do |**attributes|
      captured = attributes.fetch(:request)
      AttributionFixtures::Stream.new
    end

    client.send(:http_get_stream, "/v1/sprites", headers: { "Accept" => "application/x-ndjson" })

    expect_attributed(captured.to_hash)
    expect(captured["Accept"]).to eq("application/x-ndjson")
  end

  it "attributes direct command WebSocket handshakes through the shared builder" do
    captured = nil
    command_transport = double("WsCmd").as_null_object
    allow(Sprites::WsCmd).to receive(:new) do |**attributes|
      captured = attributes.fetch(:headers)
      command_transport
    end

    client.sprite("demo").command("true").start

    expect_attributed(captured)
  end

  it "attributes control and proxy WebSocket handshakes through the shared builder" do
    captured = []
    allow(Sprites::WebSocketConnection).to receive(:new) do |_url, headers:, **|
      captured << headers
      AttributionFixtures::WebSocket.new
    end

    control = Sprites::ControlPool.new(client, "demo").dial
    client.send(:dial_proxy_websocket, "demo")

    expect(captured.size).to eq(2)
    captured.each { |headers| expect_attributed(headers) }
  ensure
    control&.close
  end

  it "contains no second Bearer-header implementation outside ClientSignals" do
    source_root = File.expand_path("../../lib/sprites", __dir__)
    offenders = Dir[File.join(source_root, "**/*.rb")].filter_map do |path|
      next if path.end_with?("client_signals.rb")

      lines = File.readlines(path).each_with_index.filter_map do |line, index|
        "#{path}:#{index + 1}" if line.match?(/(?:=>|=)\s*[\"']Bearer /)
      end
      [ path, lines ] unless lines.empty?
    end

    expect(offenders).to be_empty
  end
end
