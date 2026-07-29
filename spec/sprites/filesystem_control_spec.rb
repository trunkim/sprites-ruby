# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::FilesystemControl do
  let(:client) { Sprites::Client.new("tok", base_url: "http://localhost:8080", disable_control: false) }
  let(:sprite) do
    Sprites::Sprite.new(name: "demo", client: client).tap do |s|
      s.instance_variable_set(:@supports_control, true)
      s.instance_variable_set(:@control_checked, true)
    end
  end

  let(:ws) do
    instance_double(Sprites::WebSocketConnection, write_text: true, write_binary: true, close: true)
  end

  let(:conn) { Sprites::ControlConn.new(ws) }

  before do
    pool = instance_double(Sprites::ControlPool)
    allow(client).to receive(:get_or_create_pool).with("demo").and_return(pool)
    allow(pool).to receive(:checkout).and_return(conn)
    allow(pool).to receive(:checkin)
    conn.busy = true
  end

  it "reads fs responses via ControlConn#read_message, never raw websocket reads" do
    expect(ws).not_to receive(:read_message)

    queue = conn.instance_variable_get(:@read_queue)
    queue << [:text, JSON.generate({ "path" => "/tmp/a", "size" => 3 })]
    queue << [:binary, "abc"]
    queue << [:text, JSON.generate({ "type" => "op.complete" })]

    result = sprite.fs_read_control("/tmp/a")
    expect(result.data).to eq("abc")
    expect(result.size).to eq(3)
  end

  it "checkin even when the operation fails" do
    pool = client.get_or_create_pool("demo")
    queue = conn.instance_variable_get(:@read_queue)
    queue << [:text, JSON.generate({ "error" => "denied", "code" => "EACCES" })]

    expect {
      sprite.fs_list_control("/secret")
    }.to raise_error(Sprites::FSError)

    expect(pool).to have_received(:checkin).with(conn)
  end
end
