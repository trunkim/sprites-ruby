# frozen_string_literal: true

require "json"
require "securerandom"

module Sprites
  # 底层 WebSocket 命令执行器
  #
  # 管理 WebSocket 连接的生命周期、I/O 循环、以及与服务端的二进制/文本帧交互。
  # 支持两种连接模式：
  # - 直接连接：每次命令新建 WebSocket
  # - 控制连接：复用 ControlPool 中的持久化 WebSocket，通过 control:op.start 协议多路复用
  #
  # 支持两种 I/O 模式：
  # - PTY 模式：原始二进制帧直通 stdout，适合交互式终端
  # - Stream 模式：二进制帧带流 ID 前缀（stdin=0, stdout=1, stderr=2, exit=3）
  class WsCmd
    attr_accessor :path, :args, :stdin, :stdout, :stderr, :env, :dir,
                  :tty, :is_attach, :attach_session_id, :max_run_after_disconnect,
                  :text_message_handler, :existing_conn, :using_control, :control_conn
    attr_reader :session_id, :capabilities, :operation_error

    def initialize(url:, headers:, name:, args: [], ctx: nil)
      @url = url
      @headers = headers
      @path = name
      @args = [name] + args
      @ctx = ctx
      @tty = false
      @is_attach = false
      @attach_session_id = nil
      @max_run_after_disconnect = nil
      @text_message_handler = nil
      @existing_conn = nil      # 复用已有的 WebSocket（控制连接）
      @using_control = false     # 是否使用控制连接协议
      @control_conn = nil        # ControlConn 实例（用于从 read_queue 读消息）
      @conn = nil                # 底层 WebSocketConnection
      @adapter = nil             # WsAdapter 写入适配器
      @start_queue = Queue.new   # 同步 start：成功放 nil，失败放 Exception
      @exit_code = nil
      @received_exit = false
      @done = false
      @done_mutex = Mutex.new
      @done_cond = ConditionVariable.new
      @session_id = nil
      @capabilities = {}
      @operation_error = nil
      @env = nil
      @dir = nil
    end

    # 异步启动：在新线程中建立连接并开始 I/O 循环
    # 阻塞等待连接建立成功或失败
    def start
      @io_thread = Thread.new { run_start }
      err = @start_queue.pop
      raise err if err.is_a?(Exception)
    end

    # 阻塞等待命令执行完成
    def wait
      @done_mutex.synchronize do
        @done_cond.wait(@done_mutex) until @done
      end
      @io_thread&.join
      nil
    end

    # 获取退出码，未收到退出消息时返回 -1
    def exit_code
      return -1 unless @received_exit

      @exit_code || 0
    end

    # 发送终端尺寸变更（仅 PTY 模式）
    def resize(width, height)
      return unless @tty && @adapter

      @adapter.write_control({ type: "resize", cols: width, rows: height })
    end

    # 发送信号给远程进程（如 INT、TERM、KILL）
    def signal(sig)
      raise Error, "websocket not connected" unless @adapter

      @adapter.write_control({ type: "signal", signal: sig })
    end

    # 检查服务端是否具备某能力（从 X-Sprite-Capabilities 头解析）
    def has_capability?(cap)
      @capabilities[cap] || false
    end

    def done?
      @done_mutex.synchronize { @done }
    end

    # 中断当前命令的本地 I/O。control 模式必须关闭当前 checkout 的
    # ControlConn，才能唤醒阻塞在 read_queue 的 reader；不能关闭整个 Client。
    def disconnect
      if @using_control && @control_conn
        @control_conn.close
      else
        @adapter&.close || @conn&.close
      end
      nil
    end

    private

    # ── 连接建立与 I/O 循环主流程 ──

    def run_start
      if @existing_conn
        # 控制连接模式：复用已有 WebSocket
        @conn = @existing_conn
        send_control_start if @using_control
      else
        # 直接模式：新建 WebSocket
        connect_websocket
      end

      if @conn.respond_to?(:capabilities)
        @capabilities = @conn.capabilities
      end

      # attach 操作需要先等 session_info 消息来确定 TTY 模式
      if @is_attach && @using_control && @control_conn
        wait_for_session_info
      end

      @adapter = WsAdapter.new(@conn, @tty)
      @start_queue << nil  # 通知 start 方法连接已建立
      run_io
    rescue => e
      @start_queue << e
      mark_done
    ensure
      # 控制连接模式下，消费可能残留的操作完成消息
      if @using_control && @control_conn
        begin
          msg = @control_conn.read_message(timeout: 0.1)
        rescue
          # ignore
        end
      end
    end

    def connect_websocket
      @conn = WebSocketConnection.new(@url, headers: @headers, timeout: 30).connect!
    rescue => e
      raise Error, "failed to connect: #{e.message}"
    end

    # 通过控制连接发送 op.start 操作启动消息
    def send_control_start
      args = {}

      if @args && !@args.empty?
        args["cmd"] = @args
        args["path"] = @path
      end

      if @env && !@env.empty?
        args["env"] = @env
      end

      args["dir"] = @dir if @dir && !@dir.empty?
      args["tty"] = "true" if @tty
      args["stdin"] = "true" if @stdin
      args["id"] = @attach_session_id if @attach_session_id
      unless @max_run_after_disconnect.nil?
        args["max_run_after_disconnect"] = @max_run_after_disconnect.to_s
      end

      envelope = {
        type: "op.start",
        op: "exec",
        args: args
      }

      payload = "control:" + JSON.generate(envelope)
      Sprites.dbg("sprites: sending control op.start", args_len: payload.length)
      @conn.write_text(payload)
    end

    # 等待服务端的 session_info 消息（attach 时需要知道 TTY 模式）
    def wait_for_session_info
      Sprites.dbg("sprites: waitForSessionInfo starting", using_control: @using_control)
      deadline = Time.now + 30

      loop do
        raise Error, "timeout waiting for session_info" if Time.now > deadline

        msg = if @using_control && @control_conn
                @control_conn.read_message(timeout: deadline - Time.now)
              else
                @conn.read_message
              end

        next unless msg

        msg_type, data = msg

        if msg_type == :text
          Sprites.dbg("sprites: waitForSessionInfo received text", data: data)
          info = JSON.parse(data) rescue nil
          if info && info["type"] == "session_info"
            @tty = info["tty"] || false
            @session_id = info["session_id"] if info["session_id"]
            @text_message_handler&.call(data)
            return
          end
          @text_message_handler&.call(data)
        end
      end
    end

    # ── I/O 循环 ──

    def run_io
      start_stdin_writer

      if @tty
        run_pty_io
      else
        run_stream_io
      end
    ensure
      mark_done
    end

    # 启动 stdin 写入线程：从 @stdin 读取数据发送到服务端
    def start_stdin_writer
      return unless @stdin

      Thread.new do
        if @tty
          # PTY 模式：直接转发原始字节
          buf = String.new(capacity: 32768)
          loop do
            break if @adapter.closed?

            n = @stdin.read(32768, buf) rescue nil
            break unless n && !n.empty?

            @adapter.write(buf.dup)
          end
        elsif @using_control && @control_conn
          # 控制连接非 PTY：发送原始字节，结束时发 EOF 标记
          buf = String.new(capacity: 32768)
          loop do
            break if @adapter.closed?

            n = @stdin.read(32768, buf) rescue nil
            break unless n && !n.empty?

            @adapter.write_raw(buf.dup)
          end
          @adapter.write_raw([STREAM_STDIN_EOF].pack("C"))
        else
          # 直接连接非 PTY：使用流 ID 前缀协议
          buf = String.new(capacity: 32768)
          loop do
            break if @adapter.closed?

            n = @stdin.read(32768, buf) rescue nil
            break unless n && !n.empty?

            @adapter.write_stream(STREAM_STDIN, buf.dup)
          end
          @adapter.write_stream(STREAM_STDIN_EOF, "")
        end
      rescue => e
        Sprites.dbg("sprites: stdin writer error", error: e.message)
      end
    end

    # PTY 模式 I/O 循环：二进制帧直接写 stdout
    def run_pty_io
      out = @stdout || $stdout

      loop do
        msg = read_message
        break unless msg

        msg_type, data = msg

        case msg_type
        when :binary
          out.write(data)
        when :text
          if data.start_with?("control:")
            return if handle_control_message(data)
            next
          end

          parsed = JSON.parse(data) rescue nil
          if parsed
            case parsed["type"]
            when "session_info"
              @session_id = parsed["session_id"] if parsed["session_id"]
            when "exit"
              @text_message_handler&.call(data)
              @received_exit = true
              @exit_code = parsed["exit_code"] || 0
              next if @using_control

              close_adapter
              return
            end
          end

          @text_message_handler&.call(data)
        when :close
          close_adapter
          @exit_code ||= 0
          return
        end
      end

      close_adapter
    end

    # Stream 模式 I/O 循环：二进制帧按流 ID 分发到 stdout/stderr
    def run_stream_io
      out = @stdout || $stdout
      err_out = @stderr || $stderr

      # 没有 stdin 时立即发送 EOF（直接连接模式）
      unless @stdin
        unless @using_control && @control_conn
          Thread.new { @adapter.write_stream(STREAM_STDIN_EOF, "") }
        end
      end

      loop do
        msg = read_message
        break unless msg

        msg_type, data = msg

        case msg_type
        when :text
          if data.start_with?("control:")
            return if handle_control_message(data)
            next
          end

          parsed = JSON.parse(data) rescue nil
          if parsed
            case parsed["type"]
            when "session_info"
              @session_id = parsed["session_id"] if parsed["session_id"]
            when "exit"
              @text_message_handler&.call(data)
              @received_exit = true
              @exit_code = parsed["exit_code"] || 0
              next if @using_control

              close_adapter
              return
            end
          end

          @text_message_handler&.call(data)
        when :binary
          next if data.empty?

          stream_id = data.getbyte(0)
          payload = data.byteslice(1..)

          case stream_id
          when STREAM_STDOUT
            out.write(payload)
          when STREAM_STDERR
            err_out.write(payload)
          when STREAM_EXIT
            @received_exit = true
            @exit_code = payload.empty? ? 0 : payload.getbyte(0)
            next if @using_control

            close_adapter
            return
          end
        when :close
          close_adapter
          return
        end
      end

      close_adapter
    end

    # control connection 的可复用边界是 op.complete，不是进程 exit frame。
    # exit 只说明命令已退出；服务端仍需完成本次 operation 的收尾与串行化。
    def handle_control_message(data)
      message = JSON.parse(data.delete_prefix("control:"))
      case message["type"]
      when "op.complete"
        args = message["args"].is_a?(Hash) ? message["args"] : {}
        unless @received_exit
          @received_exit = true
          @exit_code = args["exitCode"] || args["exit_code"] || 0
        end
        true
      when "op.error"
        args = message["args"].is_a?(Hash) ? message["args"] : {}
        @operation_error = Error.new(args["error"].to_s.empty? ? "control operation failed" : args["error"])
        true
      else
        false
      end
    rescue JSON::ParserError
      false
    end

    # 控制连接模式下不关闭 adapter（因为 WebSocket 是共享的）
    def close_adapter
      return if @using_control

      @adapter&.close
    end

    # 读取下一条消息：控制连接走 read_queue，直接连接走 WebSocket
    def read_message
      if @using_control && @control_conn
        @control_conn.read_message
      else
        @conn.read_message
      end
    end

    def mark_done
      @done_mutex.synchronize do
        @done = true
        @done_cond.broadcast
      end
    end
  end
end
