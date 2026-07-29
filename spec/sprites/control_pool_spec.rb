# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::ControlConn do
  let(:ws) { instance_double(Sprites::WebSocketConnection, close: true, write_text: true) }
  let(:conn) { described_class.new(ws) }

  it "serves busy readers from the demultiplex queue only" do
    conn.busy = true
    queue = conn.instance_variable_get(:@read_queue)
    queue << [:text, '{"type":"op.complete"}']

    expect(conn.read_message(timeout: 0.2)).to eq([:text, '{"type":"op.complete"}'])
  end

  it "does not expose a second reader API requirement on raw websocket for busy ops" do
    expect(conn).to respond_to(:read_message)
    expect(ws).not_to receive(:read_message)

    conn.busy = true
    conn.instance_variable_get(:@read_queue) << [:binary, "abc"]
    expect(conn.read_message(timeout: 0.2)).to eq([:binary, "abc"])
  end
end

RSpec.describe Sprites::ControlPool do
  let(:client) do
    Sprites::Client.new(
      "tok",
      base_url: "http://localhost:8080",
      max_control_connections: 2,
      control_drain_threshold: 2,
      control_drain_target: 1
    )
  end

  it "offer_idle accepts a connection without touching private ivars from outside" do
    pool = described_class.new(client, "demo")
    ws = instance_double(Sprites::WebSocketConnection, close: true, write_text: true)
    conn = Sprites::ControlConn.new(ws)

    pool.offer_idle(conn)
    expect(pool.size).to eq(1)
    expect(conn.busy?).to be false
  end

  it "close drains connections and marks pool closed" do
    pool = described_class.new(client, "demo")
    ws = instance_double(Sprites::WebSocketConnection, close: true, write_text: true)
    conn = Sprites::ControlConn.new(ws)
    pool.offer_idle(conn)

    pool.close
    expect(pool).to be_closed
    expect(pool.size).to eq(0)
  end
end
