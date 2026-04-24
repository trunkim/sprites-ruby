# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "openssl"

module Sprites
  # ── WebSocket 二进制帧中的流 ID 常量 ──
  STREAM_STDIN     = 0  # 标准输入
  STREAM_STDOUT    = 1  # 标准输出
  STREAM_STDERR    = 2  # 标准错误
  STREAM_EXIT      = 3  # 退出码（1 字节 payload）
  STREAM_STDIN_EOF = 4  # 标准输入 EOF 标记

  # ── WebSocket keepalive 超时（秒）──
  WS_PING_INTERVAL = 15  # 发送 ping 的间隔
  WS_PONG_WAIT     = 45  # 等待 pong 的最大时间
  WS_WRITE_WAIT    = 10  # 写操作超时

  # WebSocket 写入适配器
  #
  # 封装 WebSocketConnection，提供线程安全的写入操作。
  # 根据 PTY/非 PTY 模式选择不同的帧格式：
  # - PTY 模式：直接发送原始二进制数据
  # - 非 PTY 模式：数据前加 1 字节流 ID 前缀
  class WsAdapter
    attr_reader :conn, :pty_mode

    def initialize(conn, pty_mode)
      @conn = conn
      @pty_mode = pty_mode
      @write_mutex = Mutex.new
      @closed = false
    end

    # 发送原始二进制帧
    def write_raw(data)
      @write_mutex.synchronize do
        return if @closed

        @conn.write_binary(data)
      end
    end

    # 发送 JSON 控制消息（如 resize、signal）
    def write_control(msg)
      @write_mutex.synchronize do
        return if @closed

        @conn.write_text(JSON.generate(msg))
      end
    end

    # 发送带流 ID 前缀的数据（非 PTY 模式）
    # PTY 模式下退化为 write_raw
    def write_stream(stream_id, data)
      if @pty_mode
        write_raw(data)
      else
        msg = [stream_id].pack("C") + data
        write_raw(msg)
      end
    end

    # PTY 模式专用写入（实现 IO-like 接口）
    def write(data)
      raise "Write only supported in PTY mode" unless @pty_mode

      write_raw(data)
    end

    def close
      @write_mutex.synchronize do
        @closed = true
        @conn&.close rescue nil
      end
    end

    def closed?
      @closed
    end
  end

  # 原生 WebSocket 客户端实现（RFC 6455）
  #
  # 不依赖第三方 WebSocket 库，直接操作 TCP/SSL socket。
  # 支持 text/binary/ping/pong/close 帧，客户端到服务端的帧自动 mask。
  #
  # @example
  #   ws = WebSocketConnection.new("wss://api.sprites.dev/v1/sprites/x/exec",
  #     headers: { "Authorization" => "Bearer token" })
  #   ws.connect!
  #   ws.write_text("hello")
  #   type, data = ws.read_message  #=> [:text, "world"]
  #   ws.close
  class WebSocketConnection
    attr_reader :socket, :capabilities, :response_headers

    def initialize(uri, headers: {}, timeout: 30)
      @uri = URI(uri)
      @headers = headers
      @timeout = timeout
      @read_mutex = Mutex.new
      @write_mutex = Mutex.new
      @closed = false
      @capabilities = {}
      @response_headers = {}
    end

    # 建立 TCP/SSL 连接并完成 WebSocket 握手
    # @return [self]
    def connect!
      @socket = create_socket
      perform_handshake
      parse_capabilities
      self
    end

    # 发送文本帧（opcode 0x01）
    def write_text(data)
      write_frame(0x01, data.b)
    end

    # 发送二进制帧（opcode 0x02）
    def write_binary(data)
      write_frame(0x02, data)
    end

    # 发送 ping 帧（opcode 0x09）
    def write_ping(data = "")
      write_frame(0x09, data.b)
    end

    # 发送关闭帧（opcode 0x08）
    def write_close(code = 1000, reason = "")
      payload = [code].pack("n") + reason.encode("utf-8")
      write_frame(0x08, payload) rescue nil
    end

    # 读取下一条消息
    # @return [Array(Symbol, String), nil] [:text, data] / [:binary, data] / [:close, data] / nil
    def read_message
      @read_mutex.synchronize do
        return nil if @closed

        read_frame
      end
    end

    # 优雅关闭：发送 close 帧后关闭 socket
    def close
      return if @closed

      @closed = true
      write_close rescue nil
      @socket&.close rescue nil
    end

    def closed?
      @closed
    end

    private

    # 创建底层 socket（TCP 或 TLS-wrapped）
    def create_socket
      tcp = TCPSocket.new(@uri.host, @uri.port || (@uri.scheme == "wss" ? 443 : 80))
      tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

      if @uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        # set_params 会自动加载系统 CA 证书
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = @uri.host
        ssl.connect
        ssl
      else
        tcp
      end
    end

    # 执行 HTTP Upgrade 握手
    def perform_handshake
      key = SecureRandom.base64(16)
      path = @uri.request_uri

      request = "GET #{path} HTTP/1.1\r\n"
      request += "Host: #{@uri.host}\r\n"
      request += "Upgrade: websocket\r\n"
      request += "Connection: Upgrade\r\n"
      request += "Sec-WebSocket-Key: #{key}\r\n"
      request += "Sec-WebSocket-Version: 13\r\n"
      @headers.each { |k, v| request += "#{k}: #{v}\r\n" }
      request += "\r\n"

      @socket.write(request)

      # 读取 HTTP 响应头
      response = ""
      loop do
        line = read_line
        response += line
        break if line == "\r\n"
      end

      unless response.include?("101")
        status_match = response.match(/HTTP\/\d\.\d (\d+)/)
        status = status_match ? status_match[1] : "unknown"
        raise Error, "WebSocket handshake failed (HTTP #{status})"
      end

      # 解析响应头
      response.split("\r\n").each do |line|
        if (m = line.match(/\A([^:]+):\s*(.*)\z/))
          @response_headers[m[1]] = m[2]
        end
      end
    end

    # 从 X-Sprite-Capabilities 头解析服务端能力（如 signal）
    def parse_capabilities
      if (caps = @response_headers["X-Sprite-Capabilities"])
        caps.split(",").each { |c| @capabilities[c.strip] = true }
      end
    end

    def read_line
      line = +""
      loop do
        ch = @socket.read(1)
        raise Error, "Connection closed during handshake" unless ch

        line << ch
        break if line.end_with?("\n")
      end
      line
    end

    # 写入一个 WebSocket 帧（客户端帧必须 mask）
    def write_frame(opcode, payload)
      @write_mutex.synchronize do
        return if @closed

        frame = +""
        # FIN=1 | opcode
        frame << [0x80 | opcode].pack("C")

        mask_key = SecureRandom.random_bytes(4)
        len = payload.bytesize

        # 编码 payload 长度 + MASK 位
        if len < 126
          frame << [0x80 | len].pack("C")
        elsif len < 65536
          frame << [0x80 | 126, len].pack("Cn")
        else
          frame << [0x80 | 127, len].pack("CQ>")
        end

        # mask key + masked payload
        frame << mask_key
        masked = payload.bytes.each_with_index.map { |b, i| b ^ mask_key.bytes[i % 4] }.pack("C*")
        frame << masked

        @socket.write(frame)
      end
    end

    # 读取一个 WebSocket 帧，自动处理 ping/pong
    def read_frame
      first_byte = @socket.read(1)
      return nil unless first_byte

      first = first_byte.unpack1("C")
      opcode = first & 0x0F

      second = @socket.read(1).unpack1("C")
      masked = (second & 0x80) != 0
      len = second & 0x7F

      # 扩展长度
      if len == 126
        len = @socket.read(2).unpack1("n")
      elsif len == 127
        len = @socket.read(8).unpack1("Q>")
      end

      mask_key = masked ? @socket.read(4) : nil
      payload = len > 0 ? @socket.read(len) : +""

      # 服务端帧可能也带 mask（虽然不常见）
      if masked && mask_key && payload
        payload = payload.bytes.each_with_index.map { |b, i| b ^ mask_key.bytes[i % 4] }.pack("C*")
      end

      case opcode
      when 0x01 # text
        [:text, payload.force_encoding("utf-8")]
      when 0x02 # binary
        [:binary, payload]
      when 0x08 # close
        @closed = true
        [:close, payload]
      when 0x09 # ping — 自动回 pong
        write_frame(0x0A, payload) rescue nil
        read_frame
      when 0x0A # pong — 忽略，继续读
        read_frame
      else
        read_frame
      end
    rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError
      @closed = true
      nil
    end
  end
end
