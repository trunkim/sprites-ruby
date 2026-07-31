# frozen_string_literal: true

require "json"

module Sprites
  # ── 控制连接池常量（默认值；实际上限由 Client 注入）──
  DIAL_TIMEOUT = 30         # 新建连接的超时（秒）
  KEEP_ALIVE_WINDOW = 30    # keepalive 窗口（秒）

  # 控制连接包装器
  #
  # 包装一个 WebSocketConnection，提供：
  # - busy/idle 状态管理
  # - 后台 read_loop 线程，根据 busy 状态决定消息去向：
  #   - busy=true：消息入 read_queue，供 WsCmd 消费
  #   - busy=false：消息在 read_loop 中就地处理（keepalive 等）
  class ControlConn
    attr_reader :ws

    def initialize(ws)
      @ws = ws
      @busy = false
      @last_used = Time.now
      @mutex = Mutex.new
      @read_queue = Queue.new
      @closed = false
      @read_thread = nil
    end

    def busy?
      @mutex.synchronize { @busy }
    end

    def busy=(val)
      @mutex.synchronize { @busy = val }
    end

    def last_used
      @mutex.synchronize { @last_used }
    end

    def last_used=(val)
      @mutex.synchronize { @last_used = val }
    end

    # 启动后台读取线程
    def start_read_loop
      @mutex.synchronize do
        raise Error, "control connection is closed" if @closed
        return self if @read_thread

        @read_thread = Thread.new { read_loop }
        @read_thread.report_on_exception = false
      end
      self
    end

    # 清空消息队列（checkout 时调用，防止残留消息干扰新命令）
    def drain_queue
      loop do
        break if @read_queue.empty?
        break if @read_queue.pop(true).nil?
      end
    rescue ThreadError
      # 队列已空
    end

    # 从消息队列中读取一条消息
    # @param timeout [Float, nil] 超时秒数，nil 表示阻塞等待
    # @return [Array, nil] [:text/:binary, data] 或 nil
    def read_message(timeout: nil)
      return @read_queue.pop if timeout.nil?

      timeout = Float(timeout)
      raise ArgumentError, "timeout must be >= 0" if timeout.negative? || !timeout.finite?

      @read_queue.pop(timeout: timeout)
    rescue ThreadError, ClosedQueueError
      nil
    end

    # 发送释放消息，通知服务端此连接可复用
    def close
      thread = @mutex.synchronize do
        return if @closed

        @closed = true
        @read_thread
      end
      @read_queue.close
      begin
        @ws&.close
      rescue StandardError
        nil
      end
      if thread&.alive? && !thread.equal?(Thread.current)
        thread.join(2)
        if thread.alive?
          thread.kill
          thread.join
        end
      end
      nil
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    private

    # 后台读取循环
    # - busy 时：消息入 read_queue 给 WsCmd 消费
    # - idle 时：就地处理控制消息（keepalive/dial 等），丢弃二进制消息
    def read_loop
      loop do
        break if @closed

        msg = @ws.read_message
        break unless msg

        if busy?
          @read_queue << msg
        else
          # 空闲状态：处理服务端的控制帧
          msg_type, data = msg
          if msg_type == :text
            parsed = JSON.parse(data) rescue nil
            if parsed
              case parsed["type"]
              when "keepalive", "dial"
                Sprites.dbg("sprites: idle control msg", type: parsed["type"])
              end
            end
          end
        end
      end
    rescue => e
      Sprites.dbg("sprites: control read_loop error", error: e.message)
    ensure
      @mutex.synchronize { @closed = true }
      @read_queue.close
    end
  end

  # 控制连接池
  #
  # 为每个 sprite 维护一组持久化 WebSocket 连接。
  # 相比每次命令都新建连接，控制连接通过多路复用协议在同一连接上
  # 依次执行多个操作，减少握手开销。
  #
  # 工作流程：
  # 1. checkout —— 获取空闲连接或新建连接，标记为 busy
  # 2. 使用连接执行命令（WsCmd 通过 control:op.start 协议）
  # 3. checkin —— 标记为 idle，归还池中
  #
  # 当池中连接数超过 POOL_DRAIN_THRESHOLD 时，自动清理最久未使用的空闲连接。
  class ControlPool
    def initialize(client, sprite_name, max_size: nil, drain_threshold: nil, drain_target: nil)
      @client = client
      @sprite_name = sprite_name
      @max_size = Integer(max_size || client.max_control_connections)
      @drain_threshold = Integer(drain_threshold || client.control_drain_threshold)
      @drain_target = Integer(drain_target || client.control_drain_target)
      @mutex = Mutex.new
      @conns = []
      @pending_dials = 0
      @closed = false
    end

    # @return [Integer] 当前池中连接数（含 busy）
    def size
      @mutex.synchronize { @conns.size }
    end

    # @return [Boolean] 池是否已关闭
    def closed?
      @mutex.synchronize { @closed }
    end

    # 将探测到的空闲连接纳入池中（不修改 private ivar）
    def offer_idle(conn)
      return unless conn

      close_now = false
      to_close = @mutex.synchronize do
        if @closed
          close_now = true
          []
        else
          conn.busy = false
          conn.last_used = Time.now
          @conns << conn unless @conns.include?(conn)
          take_drain_candidates
        end
      end
      conn.close if close_now
      close_drained(to_close)
      nil
    end

    # 获取一个可用连接（优先复用空闲连接，否则新建）
    # @return [ControlConn]
    # @raise [Error] 池已关闭或达到上限
    def checkout
      @mutex.synchronize do
        raise Error, "pool is closed" if @closed

        # 清理已关闭的连接
        @conns.reject! do |conn|
          if conn.closed?
            Sprites.dbg("sprites: removed closed control conn", sprite: @sprite_name, pool: @conns.size)
            true
          else
            false
          end
        end

        # 查找空闲连接
        idle = @conns.find { |c| !c.busy? && !c.closed? }
        if idle
          idle.drain_queue  # 清空残留消息
          idle.busy = true
          Sprites.dbg("sprites: checkout control conn", sprite: @sprite_name, pool: @conns.size)
          return idle
        end

        if @conns.size + @pending_dials >= @max_size
          raise Error, "no available connections in pool (at cap #{@max_size})"
        end

        # 在锁外新建连接，避免阻塞其他操作
        @pending_dials += 1
      end

      conn = dial
      @mutex.synchronize do
        @pending_dials -= 1
        if @closed
          conn.close
          raise Error, "pool closed during dial"
        end

        conn.busy = true
        @conns << conn
        Sprites.dbg("sprites: dialed new control conn", sprite: @sprite_name, pool: @conns.size)
      end
      conn
    rescue
      @mutex.synchronize { @pending_dials -= 1 } if conn.nil?
      raise
    end

    # 归还连接到池中
    def checkin(conn)
      return unless conn

      conn.busy = false
      conn.last_used = Time.now
      Sprites.dbg("sprites: checkin control conn", sprite: @sprite_name)

      to_close = @mutex.synchronize { take_drain_candidates }
      close_drained(to_close)
      nil
    end

    # 关闭池中所有连接
    def close
      connections = @mutex.synchronize do
        return if @closed

        @closed = true
        snapshot = @conns.dup
        @conns.clear
        snapshot
      end
      connections.each(&:close)
      nil
    end

    # 新建一个控制连接
    # @return [ControlConn]
    def dial(_ctx = nil)
      url = build_control_url

      headers = {
        "Authorization" => "Bearer #{@client.token}",
        "User-Agent" => "sprites-ruby-sdk/#{VERSION}"
      }

      ws = WebSocketConnection.new(url, headers: headers, timeout: DIAL_TIMEOUT).connect!
      conn = ControlConn.new(ws)
      conn.start_read_loop

      Sprites.dbg("sprites: created control conn", sprite: @sprite_name)
      conn
    rescue => e
      raise Error, "failed to dial control connection: #{e.message}"
    end

    # 构建控制端点的 WebSocket URL
    def build_control_url
      Routes.websocket_uri(@client.base_url, Routes.control(@sprite_name)).to_s
    end

    private

    # 当连接数超过阈值时，关闭最久未使用的空闲连接（LRU）
    def take_drain_candidates
      return [] if @closed || @conns.size <= @drain_threshold

      idles = @conns.select { |c| !c.busy? && !c.closed? }
                     .sort_by(&:last_used)

      to_close = @conns.size - @drain_target
      return [] if to_close <= 0 || idles.empty?

      to_close = [to_close, idles.size].min
      close_set = idles.first(to_close)
      @conns.reject! { |conn| close_set.include?(conn) }
      close_set
    end

    def close_drained(close_set)
      close_set.each(&:close)
      Sprites.dbg("sprites: drained control pool", sprite: @sprite_name, pool_size: size) unless close_set.empty?
    end
  end
end
