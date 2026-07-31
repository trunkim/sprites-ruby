# frozen_string_literal: true

require "stringio"
require "uri"

module Sprites
  # 远程命令执行器
  #
  # 对标 Go 标准库的 exec.Cmd 接口，提供在远程 Sprite 上执行命令的能力。
  # 支持 stdin/stdout/stderr 重定向、pipe、TTY 模式、信号发送等。
  #
  # @example 基本用法
  #   cmd = sprite.command("ls", "-la")
  #   err = cmd.run
  #
  # @example 获取输出
  #   output, err = sprite.command("echo", "hello").output
  #
  # @example 使用 pipe
  #   cmd = sprite.command("cat")
  #   stdin = cmd.stdin_pipe
  #   stdout = cmd.stdout_pipe
  #   cmd.start
  #   stdin.write("hello\n")
  #   stdin.close
  #   puts stdout.read
  #   cmd.wait
  #
  # @example TTY 模式
  #   cmd = sprite.command("bash")
  #   cmd.set_tty(true)
  #   cmd.set_tty_size(24, 80)
  #   cmd.run
  class Cmd
    # @return [String] 要执行的命令路径
    attr_accessor :path
    # @return [Array<String>] 命令参数（包含 path 作为 args[0]）
    attr_accessor :args
    # @return [Array<String>, nil] 环境变量，格式 ["KEY=value", ...]
    attr_accessor :env
    # @return [String, nil] 工作目录
    attr_accessor :dir
    # @return [IO, nil] 标准输入源
    attr_accessor :stdin
    # @return [IO, nil] 标准输出目标
    attr_accessor :stdout
    # @return [IO, nil] 标准错误目标
    attr_accessor :stderr
    # @return [Proc, nil] 文本消息回调（用于端口通知等带外消息）
    attr_accessor :text_message_handler
    # @return [Integer, nil] 断连后允许继续运行的秒数（官方 max_run_after_disconnect）
    attr_accessor :max_run_after_disconnect

    def initialize(sprite:, name:, args: [], ctx: nil)
      @sprite = sprite
      @path = name
      @args = [name] + args
      @ctx = ctx
      @env = nil
      @dir = nil
      @stdin = nil
      @stdout = nil
      @stderr = nil
      @text_message_handler = nil
      @max_run_after_disconnect = nil

      @mutex = Mutex.new
      @started = false
      @finished = false
      @wait_err = nil
      @exit_code = 0

      @stdin_pipe = nil
      @stdout_pipe = nil
      @stderr_pipe = nil
      @closers = []  # start 后需要关闭的 IO 对象

      @tty = false
      @tty_size = nil
      @session_id = nil     # attach 时使用
      @detachable = false
      @control_mode = false
      @control_conn = nil
      @ws_cmd = nil
    end

    def to_s
      "#{@path} #{@args[1..].join(' ')}"
    end

    # @return [String] "control"、"direct" 或 ""（未启动时）
    def connection_mode
      @mutex.synchronize do
        return "" unless @started

        @control_mode ? "control" : "direct"
      end
    end

    # 启动命令并等待完成
    # @return [nil, ExitError, Error] nil 表示成功
    def run
      start
      wait
    end

    # 异步启动命令（不等待完成）
    # @raise [AlreadyStartedError] 重复启动
    def start
      @mutex.synchronize do
        raise AlreadyStartedError if @started

        @started = true
      end

      # attach 操作需要知道服务端版本以选择正确的端点格式
      if @session_id && @sprite.client.sprite_version.empty?
        @sprite.client.fetch_version(@sprite.name)
      end

      # 延迟检测控制连接支持
      @sprite.ensure_control_support

      # 尝试使用控制连接（更快，可复用）
      control_conn = nil
      using_control = false

      if @sprite.supports_control?
        pool = @sprite.client.get_or_create_pool(@sprite.name)
        begin
          control_conn = pool.checkout
          if control_conn
            using_control = true
            @control_mode = true
            Sprites.dbg("sprites: using control conn for exec", sprite: @sprite.name)
          end
        rescue => e
          Sprites.dbg("sprites: control checkout failed", error: e.message)
        end
      end

      # 构建 WebSocket URL 并创建底层命令执行器
      ws_url = build_websocket_url
      headers = { "Authorization" => "Bearer #{@sprite.client.token}" }

      cmd_args = @args.length > 1 ? @args[1..] : []
      @ws_cmd = WsCmd.new(url: ws_url, headers: headers, name: @path, args: cmd_args)

      if using_control
        @ws_cmd.existing_conn = control_conn.ws
        @ws_cmd.using_control = true
        @ws_cmd.control_conn = control_conn
      end

      configure_ws_cmd!(@ws_cmd)
      track_ws_cmd!(@ws_cmd)

      begin
        @ws_cmd.start
      rescue => e
        # path-based attach 返回 404 时，回退到 legacy query parameter 格式
        if @session_id && !@sprite.use_legacy_exec_endpoint? &&
           e.message.include?("HTTP 404")
          release_control_conn!(control_conn)
          control_conn = nil
          using_control = false

          @sprite.use_legacy_exec_endpoint = true
          # attach 回退路径仍要求调用方已显式 set_tty；不在此隐式打开 TTY

          ws_url = build_websocket_url
          @ws_cmd = WsCmd.new(url: ws_url, headers: headers, name: @path, args: cmd_args)
          configure_ws_cmd!(@ws_cmd)
          track_ws_cmd!(@ws_cmd)
          @ws_cmd.is_attach = true
          @ws_cmd.start
          return
        end

        release_control_conn!(control_conn)
        raise Error, "failed to start sprite command: #{e.message}"
      end

      @control_conn = control_conn if using_control
    end

    # 等待命令完成，返回错误（nil 表示成功）
    # @return [nil, ExitError, Error]
    # @raise [NotStartedError] 未调用 start
    def wait
      @mutex.synchronize do
        raise NotStartedError unless @started
        return @wait_err if @finished
      end

      raise Error, "command not fully initialized" unless @ws_cmd

      begin
        @ws_cmd.wait
        @exit_code = @ws_cmd.exit_code
        operation_error = @ws_cmd.operation_error
      ensure
        @stdin_pipe&.close rescue nil
        release_control_conn!(@control_conn)
        @control_conn = nil
        @closers.each { |c| c.close rescue nil }
      end

      @mutex.synchronize do
        @finished = true

        if operation_error
          @wait_err = operation_error
        elsif @exit_code == -1
          @wait_err = Error.new("connection closed")
        elsif @exit_code != 0
          @wait_err = ExitError.new(@exit_code)
        end

        @wait_err
      end
    end

    # 幂等关闭：等待已启动命令结束，或仅释放尚未 wait 的资源。
    def close
      return unless @started

      wait unless @finished
    rescue Error
      release_control_conn!(@control_conn)
      @control_conn = nil
    end

    # 只断开当前命令占用的 transport，不关闭 Client，也不向远端发送 signal。
    # 远端命令是否继续运行由 max_run_after_disconnect 决定；调用方必须另行确认
    # session 终态，不能把 transport 断开本身当作命令已经结束。
    def disconnect
      ws_cmd = @mutex.synchronize { @ws_cmd }
      ws_cmd&.disconnect
      nil
    end

    # 执行命令并返回 stdout 内容
    # @return [Array(String, nil)] [输出内容, 错误]
    def output
      raise Error, "sprite: Stdout already set" if @stdout

      buf = StringIO.new
      @stdout = buf

      err = run
      [buf.string, err]
    end

    # 执行命令并返回 stdout + stderr 合并内容
    # @return [Array(String, nil)] [合并内容, 错误]
    def combined_output
      raise Error, "sprite: Stdout already set" if @stdout
      raise Error, "sprite: Stderr already set" if @stderr

      buf = StringIO.new
      @stdout = buf
      @stderr = buf

      err = run
      [buf.string, err]
    end

    # 创建连接到 stdin 的 pipe，返回写入端
    # @return [IO] pipe 写入端
    def stdin_pipe
      raise Error, "sprite: Stdin already set" if @stdin
      raise Error, "sprite: StdinPipe after process started" if @started

      rd, wr = IO.pipe
      @stdin = rd
      @closers << rd
      wr
    end

    # 创建连接到 stdout 的 pipe，返回读取端
    # @return [IO] pipe 读取端
    def stdout_pipe
      raise Error, "sprite: Stdout already set" if @stdout
      raise Error, "sprite: StdoutPipe after process started" if @started

      rd, wr = IO.pipe
      @stdout = wr
      @closers << wr
      rd
    end

    # 创建连接到 stderr 的 pipe，返回读取端
    # @return [IO] pipe 读取端
    def stderr_pipe
      raise Error, "sprite: Stderr already set" if @stderr
      raise Error, "sprite: StderrPipe after process started" if @started

      rd, wr = IO.pipe
      @stderr = wr
      @closers << wr
      rd
    end

    # 启用/禁用 TTY 模式（必须在 start 前调用）
    def set_tty(enable)
      @mutex.synchronize do
        raise "sprite: SetTTY after process started" if @started

        @tty = enable
      end
    end

    # 设置断连后最大继续运行秒数（必须在 start 前调用）
    # @param seconds [Integer] 秒；非 TTY 官方默认 10，TTY 默认无限（0）
    def set_max_run_after_disconnect(seconds)
      @mutex.synchronize do
        raise Error, "sprite: SetMaxRunAfterDisconnect after process started" if @started

        value = Integer(seconds)
        raise ArgumentError, "max_run_after_disconnect must be >= 0" if value.negative?

        @max_run_after_disconnect = value
      end
      self
    end

    # 创建可再次 attach 的 detachable session（必须在 start 前调用）。
    def set_detachable(enable = true)
      @mutex.synchronize do
        raise Error, "sprite: SetDetachable after process started" if @started

        @detachable = enable == true
      end
      self
    end

    # 设置终端尺寸（start 前设初始大小，start 后调整运行中的终端）
    def set_tty_size(rows, cols)
      @mutex.synchronize do
        raise Error, "sprite: SetTTYSize called but TTY mode not enabled" unless @tty

        if @started && !@finished
          raise Error, "command not fully initialized" unless @ws_cmd

          return @ws_cmd.resize(cols, rows)
        end

        @tty_size = { rows: rows, cols: cols }
      end
    end

    # 调整运行中的 TTY 终端尺寸
    def resize(rows, cols)
      @mutex.synchronize do
        raise Error, "sprite: Resize before process started" unless @started
        raise Error, "sprite: Resize called but TTY mode not enabled" unless @tty
        raise Error, "sprite: Resize after process finished" if @finished
        raise Error, "command not fully initialized" unless @ws_cmd

        @ws_cmd.resize(cols, rows)
      end
    end

    # 发送信号给远程进程
    # 优先通过 WebSocket 发送，不支持时回退到 HTTP POST
    # @param sig [String] 信号名（INT, TERM, HUP, KILL, QUIT, USR1, USR2）
    def signal(sig)
      @mutex.synchronize do
        raise Error, "sprite: Signal before process started" unless @started
        raise Error, "sprite: Signal after process finished" if @finished

        # @ws_cmd 可能已断开为 nil；不得对 nil 调 has_capability?（Gateway 曾因此 NoMethodError）。
        if @ws_cmd&.has_capability?("signal")
          return @ws_cmd.signal(sig)
        end

        # HTTP 回退
        sess_id = @session_id || @ws_cmd&.session_id
        raise Error, "sprite: no session ID for HTTP signal fallback" unless sess_id

        @sprite.client.signal_session(@sprite.name, sess_id, sig)
      end
    end

    # @return [Integer] 退出码，未完成时返回 -1
    def exit_code
      @mutex.synchronize do
        return -1 unless @finished

        @exit_code
      end
    end

    # 手动设置控制模式（需要 session_id）
    def set_control_mode(enable)
      @mutex.synchronize do
        raise Error, "sprite: SetControlMode after process started" if @started
        raise Error, "sprite: control mode requires session ID" if enable && !@session_id

        @control_mode = enable
      end
    end

    protected

    attr_writer :session_id

    private

    # 构建 exec 端点的 WebSocket URL
    def build_websocket_url
      params = []

      # attach 操作：根据版本选择 path 格式或 query 格式
      if @session_id
        if @sprite.use_legacy_exec_endpoint? || !@sprite.client.supports_path_attach?
          path = Routes.exec(@sprite.name)
          params << ["id", @session_id]
        else
          path = Routes.session(@sprite.name, @session_id)
        end
      else
        path = Routes.exec(@sprite.name)
      end

      # 新建命令时添加 cmd 和 path 参数
      unless @session_id
        @args.each_with_index do |arg, i|
          params << ["cmd", arg]
          params << ["path", arg] if i == 0
        end
      end

      @env&.each { |e| params << ["env", e] }
      params << ["dir", @dir] if @dir && !@dir.empty?

      if @tty
        params << ["tty", "true"]
        if @tty_size
          params << ["rows", @tty_size[:rows].to_s]
          params << ["cols", @tty_size[:cols].to_s]
        end
      end

      params << ["cc", "true"] if @control_mode
      params << ["detachable", "true"] if @detachable && !@session_id
      params << ["stdin", @stdin ? "true" : "false"]
      if !@session_id && !@max_run_after_disconnect.nil?
        params << ["max_run_after_disconnect", @max_run_after_disconnect.to_s]
      end

      Routes.websocket_uri(@sprite.client.base_url, path, params: params).to_s
    end

    def configure_ws_cmd!(ws_cmd)
      ws_cmd.stdin = @stdin
      ws_cmd.stdout = @stdout
      ws_cmd.stderr = @stderr
      ws_cmd.tty = @tty
      ws_cmd.is_attach = !@session_id.nil?
      ws_cmd.attach_session_id = @session_id
      ws_cmd.env = @env
      ws_cmd.dir = @dir
      ws_cmd.text_message_handler = @text_message_handler
      ws_cmd.max_run_after_disconnect = @max_run_after_disconnect
      ws_cmd.detachable = @detachable
    end

    def release_control_conn!(conn)
      return unless conn

      pool = @sprite.client.get_or_create_pool(@sprite.name)
      pool.checkin(conn)
      Sprites.dbg("sprites: returned control conn after exec", sprite: @sprite.name)
    rescue => e
      Sprites.dbg("sprites: control checkin failed", error: e.message)
    end

    def track_ws_cmd!(ws_cmd)
      ws_cmd.on_release = -> { @sprite.client.untrack_connection(ws_cmd) }
      @sprite.client.track_connection(ws_cmd)
    end
  end
end
