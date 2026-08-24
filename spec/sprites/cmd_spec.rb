# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Cmd do
  class BlockingCommandConnection
    attr_reader :capabilities

    def initialize
      @messages = Queue.new
      @capabilities = {}
      @closed = false
      @mutex = Mutex.new
    end

    def connect! = self
    def write_binary(_payload) = nil
    def write_text(_payload) = nil
    def read_message = @messages.pop

    def emit(message)
      @messages << message
    end

    def close
      should_wake = @mutex.synchronize do
        next false if @closed

        @closed = true
        true
      end
      @messages << nil if should_wake
    end

    def closed? = @mutex.synchronize { @closed }
  end

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

  describe "detachable sessions" do
    it "writes detachable on direct and control protocols" do
      cmd = sprite.create_session("bash", "-l")
      params = URI.decode_www_form(URI.parse(cmd.send(:build_websocket_url)).query)
      expect(params).to include(["tty", "true"], ["detachable", "true"])

      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "bash")
      ws.detachable = true
      conn = instance_double(Sprites::WebSocketConnection, write_text: nil)
      ws.instance_variable_set(:@conn, conn)
      ws.send(:send_control_start)

      expect(conn).to have_received(:write_text) do |payload|
        expect(JSON.parse(payload.delete_prefix("control:")).dig("args", "detachable")).to eq("true")
      end
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

    it "收到 exit frame 后等待 op.complete 才结束 control operation" do
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "echo", args: [])
      ws.using_control = true
      output = StringIO.new
      ws.stdout = output
      messages = Queue.new
      messages << [:binary, [Sprites::STREAM_STDOUT].pack("C") + "ok"]
      messages << [:binary, [Sprites::STREAM_EXIT, 0].pack("CC")]
      messages << [:text, "control:" + JSON.generate(type: "op.complete", args: { exitCode: 0 })]
      control_conn = instance_double(Sprites::ControlConn)
      allow(control_conn).to receive(:read_message) { messages.pop }
      ws.control_conn = control_conn

      ws.send(:run_stream_io)

      expect(output.string).to eq("ok")
      expect(ws.exit_code).to eq(0)
      expect(control_conn).to have_received(:read_message).exactly(3).times
    end

    it "把 op.error 保留为 command error" do
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "echo", args: [])

      terminal = ws.send(
        :handle_control_message,
        "control:" + JSON.generate(type: "op.error", args: { error: "busy" })
      )

      expect(terminal).to be true
      expect(ws.operation_error).to be_a(Sprites::Error)
      expect(ws.operation_error.message).to eq("busy")
    end
  end

  describe "#signal" do
    it "capability header 缺失时仍优先通过当前 WebSocket 发送" do
      cmd = described_class.new(sprite: sprite, name: "sleep", args: ["60"])
      ws_cmd = instance_double(Sprites::WsCmd, signal: nil, session_id: nil)
      cmd.instance_variable_set(:@started, true)
      cmd.instance_variable_set(:@finished, false)
      cmd.instance_variable_set(:@ws_cmd, ws_cmd)
      expect(client).not_to receive(:signal_session)

      expect { cmd.signal("KILL") }.not_to raise_error
      expect(ws_cmd).to have_received(:signal).with("KILL")
    end

    it "WebSocket 不可用且有 session id 时回退 HTTP" do
      cmd = described_class.new(sprite: sprite, name: "sleep", args: ["60"])
      ws_cmd = instance_double(Sprites::WsCmd, session_id: "42")
      allow(ws_cmd).to receive(:signal).and_raise(Sprites::Error, "websocket is closed")
      cmd.instance_variable_set(:@started, true)
      cmd.instance_variable_set(:@finished, false)
      cmd.instance_variable_set(:@ws_cmd, ws_cmd)
      allow(client).to receive(:signal_session)

      expect { cmd.signal("KILL") }.not_to raise_error
      expect(client).to have_received(:signal_session).with("demo", "42", "KILL")
    end

    it "WebSocket 不可用且没有 session id 时保留 transport 错误" do
      cmd = described_class.new(sprite: sprite, name: "sleep", args: ["60"])
      ws_cmd = instance_double(Sprites::WsCmd, session_id: nil)
      allow(ws_cmd).to receive(:signal).and_raise(Sprites::Error, "websocket is closed")
      cmd.instance_variable_set(:@started, true)
      cmd.instance_variable_set(:@finished, false)
      cmd.instance_variable_set(:@ws_cmd, ws_cmd)
      expect(client).not_to receive(:signal_session)

      expect { cmd.signal("KILL") }.to raise_error(Sprites::Error, "websocket is closed")
    end

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


  describe "WsCmd thread lifecycle" do
    it "cannot be started after its Client-owned transport was closed" do
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "true")
      ws.close

      expect { ws.start }.to raise_error(Sprites::Error, /closed/)
    end

    it "sends stdin EOF synchronously when there is no stdin" do
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "true")
      adapter = instance_double(Sprites::WsAdapter, write_stream: nil, close: nil)
      conn = instance_double(Sprites::WebSocketConnection, read_message: [:close, ""])
      ws.instance_variable_set(:@adapter, adapter)
      ws.instance_variable_set(:@conn, conn)

      ws.send(:run_io)

      expect(adapter).to have_received(:write_stream).with(Sprites::STREAM_STDIN_EOF, "").once
      expect(ws.instance_variable_get(:@stdin_thread)).to be_nil
    end

    it "terminates its own blocked stdin forwarding thread after remote completion" do
      reader, writer = IO.pipe
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "cat")
      ws.stdin = reader
      adapter = instance_double(Sprites::WsAdapter, closed?: false, close: nil)
      conn = instance_double(Sprites::WebSocketConnection, read_message: [:close, ""])
      ws.instance_variable_set(:@adapter, adapter)
      ws.instance_variable_set(:@conn, conn)

      ws.send(:run_io)

      expect(ws.instance_variable_get(:@stdin_thread)).to be_nil
    ensure
      reader&.close
      writer&.close
    end

    it "preserves an I/O failure that happens after start succeeds" do
      ws = Sprites::WsCmd.new(url: "wss://example/exec", headers: {}, name: "true")
      conn = instance_double(
        Sprites::WebSocketConnection,
        capabilities: {},
        write_binary: nil,
        close: nil
      )
      allow(conn).to receive(:read_message).and_raise(IOError, "broken socket")
      allow(ws).to receive(:connect_websocket) { ws.instance_variable_set(:@conn, conn) }

      ws.start
      ws.wait

      expect(ws.operation_error).to be_a(Sprites::Error)
      expect(ws.operation_error.message).to eq("broken socket")
    end
  end

  describe "parallel direct command isolation" do
    it "disconnects one blocked command without closing its sibling connection" do
      real_client = Sprites::Client.new(
        "token",
        base_url: "https://example.test",
        disable_control: true
      )
      first_connection = BlockingCommandConnection.new
      second_connection = BlockingCommandConnection.new
      allow(Sprites::WebSocketConnection).to receive(:new)
        .and_return(first_connection, second_connection)
      first = real_client.sprite("demo").command("sleep", "60")
      second = real_client.sprite("demo").command("sleep", "60")

      first.start
      second.start
      expect(real_client.open_connection_count).to eq(2)

      first.disconnect
      expect(first.wait).to be_a(Sprites::Error)
      expect(second_connection).not_to be_closed
      expect(real_client.open_connection_count).to eq(1)

      second_connection.emit([:binary, [Sprites::STREAM_EXIT, 0].pack("CC")])
      expect(second.wait).to be_nil
      expect(real_client.open_connection_count).to eq(0)
    ensure
      real_client&.close
    end
  end
end
