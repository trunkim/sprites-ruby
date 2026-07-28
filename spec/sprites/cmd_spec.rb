# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Cmd do
  let(:client) do
    instance_double(
      Sprites::Client,
      token: "tok",
      base_url: "https://api.sprites.dev",
      supports_path_attach?: true
    )
  end
  let(:sprite) do
    Sprites::Sprite.new(name: "demo", client: client).tap do |s|
      allow(s).to receive(:use_legacy_exec_endpoint?).and_return(false)
    end
  end

  describe "#set_max_run_after_disconnect" do
    it "写入 query 参数（秒）" do
      cmd = described_class.new(sprite: sprite, name: "echo", args: ["hi"])
      cmd.set_max_run_after_disconnect(15)

      url = cmd.send(:build_websocket_url)
      params = URI.decode_www_form(URI.parse(url).query)

      expect(params).to include([ "max_run_after_disconnect", "15" ])
    end

    it "拒绝负数" do
      cmd = described_class.new(sprite: sprite, name: "echo", args: [])
      expect { cmd.set_max_run_after_disconnect(-1) }.to raise_error(ArgumentError)
    end

    it "attach 时不写入新建命令参数" do
      cmd = described_class.new(sprite: sprite, name: "", args: [])
      cmd.send(:session_id=, "42")
      cmd.set_max_run_after_disconnect(15)

      url = cmd.send(:build_websocket_url)
      params = URI.decode_www_form(URI.parse(url).query)

      expect(params.map(&:first)).not_to include("max_run_after_disconnect")
    end
  end

  describe "WsCmd control start" do
    it "把 max_run_after_disconnect 放进 op.start args" do
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "echo", args: [])
      ws.max_run_after_disconnect = 12
      conn = instance_double(Sprites::WebSocketConnection)
      allow(conn).to receive(:write_text)
      ws.instance_variable_set(:@conn, conn)

      ws.send(:send_control_start)

      expect(conn).to have_received(:write_text) do |payload|
        body = JSON.parse(payload.delete_prefix("control:"))
        expect(body.dig("args", "max_run_after_disconnect")).to eq("12")
      end
    end
  end
end
