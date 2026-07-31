# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe Sprites::Proxy do
  class FakeProxyWebSocket
    attr_reader :writes

    def initialize(messages = [])
      @messages = messages.dup
      @writes = []
      @closed = false
    end

    def read_message = @messages.shift
    def write_binary(data) = @writes << data
    def write_text(data) = @writes << data
    def close = @closed = true
    def closed? = @closed
  end

  class BlockingRemoteProxy
    attr_reader :writes

    def initialize
      @reads = Queue.new
      @writes = Queue.new
      @closed = false
      @mutex = Mutex.new
    end

    def write(data)
      raise IOError, "closed" if closed?

      @writes << data.dup
      data.bytesize
    end

    def read(_length) = @reads.pop

    def close
      wake = @mutex.synchronize do
        next false if @closed

        @closed = true
        true
      end
      @reads << nil if wake
    end

    def closed? = @mutex.synchronize { @closed }
  end

  let(:client) do
    Sprites::Client.new("token", base_url: "https://example.test", disable_control: true)
  end

  after { client.close }

  it "returns available WebSocket payload immediately instead of waiting to fill the requested length" do
    ws = FakeProxyWebSocket.new([
      [:binary, "abc"],
      [:binary, "def"],
      [:close, ""]
    ])
    released = 0
    connection = Sprites::ProxyConn.new(ws, "localhost:3000")
    connection.on_close = -> { released += 1 }

    expect(connection.read(2)).to eq("ab")
    expect(connection.read(32_768)).to eq("c")
    expect(connection.read(32_768)).to eq("def")
    expect(connection.read(32_768)).to be_nil
    expect(connection).to be_closed
    expect(released).to eq(1)
  end

  it "validates proxy handshake frame/address and closes a failed WebSocket" do
    ws = FakeProxyWebSocket.new([[:binary, JSON.generate(status: "connected")]])

    expect { client.send(:init_socket_tcp, ws, "localhost:3000") }
      .to raise_error(Sprites::Error, /response frame/)
    expect(ws).to be_closed
    expect(client.send(:parse_proxy_addr, "[::1]:443")).to eq(["::1", 443])
    expect { client.send(:parse_proxy_addr, "::1:443") }
      .to raise_error(Sprites::Error, /invalid address/)
    expect { client.send(:parse_proxy_addr, "localhost:nope") }
      .to raise_error(Sprites::Error, /invalid port/)
  end

  it "closes active local and remote tunnel I/O and joins owned threads" do
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.ip_port
    remote = BlockingRemoteProxy.new
    provider = Object.new
    provider.define_singleton_method(:dial_proxy_websocket) { |_name| Object.new }
    provider.define_singleton_method(:init_socket_tcp) { |_ws, _addr| remote }
    released = 0
    session = Sprites::ProxySession.new(
      local_port: port,
      remote_port: 3000,
      remote_host: "localhost",
      listener:,
      client: provider,
      sprite_name: "demo",
      on_close: -> { released += 1 }
    ).start_accept_loop
    local = TCPSocket.new("127.0.0.1", port)
    local.write("hello")

    expect(remote.writes.pop).to eq("hello")
    session.close
    session.wait

    expect(session).to be_closed
    expect(remote).to be_closed
    expect(released).to eq(1)
    expect(session.instance_variable_get(:@handler_threads)).to be_empty
  ensure
    local&.close
    session&.close
    listener&.close unless listener&.closed?
  end

  it "registers listening proxy sessions in the Client lifecycle" do
    session = client.proxy_port("demo", 0, 3000)

    expect(client.open_connection_count).to eq(1)
    client.close

    expect(session).to be_closed
    expect(client.open_connection_count).to eq(0)
  ensure
    session&.close
  end
end
