# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Sprites WebSocket watchers" do
  class FakeWatcherConnection
    attr_reader :written

    def initialize(messages = [])
      @messages = messages.dup
      @written = []
      @closed = false
    end

    def connect! = self
    def write_text(payload) = @written << payload

    def read_message
      @messages.shift
    end

    def close
      @closed = true
    end

    def closed? = @closed
  end

  let(:client) do
    Sprites::Client.new("token", base_url: "https://example.test", disable_control: true)
  end

  after { client.close }

  it "watches encoded Sprite ports, skips malformed frames, and releases on remote close" do
    connection = FakeWatcherConnection.new([
      [:text, "not-json"],
      [:binary, "ignored"],
      [:text, JSON.generate(type: "port_list", ports: [])],
      [:text, JSON.generate(type: "port_opened", port: 3000, address: "0.0.0.0", pid: 2)],
      [:close, ""]
    ])
    expect(Sprites::WebSocketConnection).to receive(:new).with(
      "wss://example.test/v1/sprites/demo%2Fname/ports/watch",
      headers: hash_including(
        "Authorization" => "Bearer token",
        "User-Agent" => a_string_starting_with("sprites-ruby/"),
        "Fly-Client-Interactive" => a_string_matching(/\A(?:true|false)\z/),
        "Fly-Client-Parent" => a_string_matching(/\A(?:node|python|shell|other)\z/)
      ),
      timeout: 30.0
    ).and_return(connection)

    watcher = client.sprite("demo/name").watch_ports

    expect(client.open_connection_count).to eq(1)
    expect(watcher.next_event).to eq(Sprites::PortList.new(type: "port_list", ports: []))
    expect(watcher.next_event.port).to eq(3000)
    expect(watcher.next_event).to be_nil
    expect(watcher).to be_closed
    expect(client.open_connection_count).to eq(0)
  end

  it "sends the official filesystem subscription and maps event wire fields" do
    connection = FakeWatcherConnection.new([
      [:text, JSON.generate(
        type: "event", path: "src/a.rb", event: "write", isDir: false, size: 4
      )]
    ])
    allow(Sprites::WebSocketConnection).to receive(:new).and_return(connection)

    watcher = client.sprite("demo").filesystem_at("/app").watch(
      ["src", "test"],
      recursive: true
    )
    event = watcher.next_event

    expect(JSON.parse(connection.written.fetch(0))).to eq(
      "type" => "subscribe",
      "paths" => ["src", "test"],
      "recursive" => true,
      "workingDir" => "/app"
    )
    expect(event.to_h).to include(
      type: "event", path: "src/a.rb", event: "write", is_dir: false, size: 4
    )
  ensure
    watcher&.close
  end

  it "rejects empty subscriptions before dialing" do
    expect(Sprites::WebSocketConnection).not_to receive(:new)

    expect { client.watch_filesystem("demo", []) }
      .to raise_error(ArgumentError, /at least one path/)
    expect { client.watch_filesystem("demo", [""]) }
      .to raise_error(ArgumentError, /must not be empty/)
  end

  it "closes registered watchers when the Client closes" do
    connection = FakeWatcherConnection.new
    allow(Sprites::WebSocketConnection).to receive(:new).and_return(connection)
    watcher = client.watch_ports("demo")

    client.close

    expect(watcher).to be_closed
    expect(connection).to be_closed
    expect(client.open_connection_count).to eq(0)
  end
end
