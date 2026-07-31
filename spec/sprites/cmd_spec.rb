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

  describe "#signal" do
    it "ws_cmd 为 nil 时回退 HTTP，不抛 NoMethodError" do
      cmd = described_class.new(sprite: sprite, name: "sleep", args: ["60"])
      cmd.instance_variable_set(:@started, true)
      cmd.instance_variable_set(:@finished, false)
      cmd.instance_variable_set(:@ws_cmd, nil)
      cmd.send(:session_id=, "42")
      allow(client).to receive(:signal_session)

      expect { cmd.signal("KILL") }.not_to raise_error
      expect(client).to have_received(:signal_session).with("demo", "42", "KILL")
    end
  end

  describe "#disconnect" do
    it "只委托当前 WsCmd，不关闭共享 Client" do
      cmd = described_class.new(sprite: sprite, name: "sleep", args: ["60"])
      ws_cmd = instance_double(Sprites::WsCmd, disconnect: nil)
      cmd.instance_variable_set(:@ws_cmd, ws_cmd)

      expect { cmd.disconnect }.not_to raise_error
      expect(ws_cmd).to have_received(:disconnect)
      expect(client).not_to receive(:close)
    end

    it "control 模式关闭当前 ControlConn 以唤醒 reader" do
      ws_cmd = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "sleep", args: ["60"])
      control_conn = instance_double(Sprites::ControlConn, close: nil)
      ws_cmd.using_control = true
      ws_cmd.control_conn = control_conn

      ws_cmd.disconnect

      expect(control_conn).to have_received(:close)
    end
  end
end
