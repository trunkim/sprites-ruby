# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "openssl"
require "socket"
require "io/wait"
require "base64"
require "digest/sha1"

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
  #     headers: ClientSignals.auth_headers("token"))
  #   ws.connect!
  #   ws.write_text("hello")
  #   type, data = ws.read_message  #=> [:text, "world"]
  #   ws.close
  class WebSocketConnection
    WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    MAX_HANDSHAKE_LINE_BYTES = 8 * 1024
    MAX_HANDSHAKE_BYTES = 64 * 1024
    MAX_FRAME_PAYLOAD_BYTES = 16 * 1024 * 1024
    RESERVED_REQUEST_HEADERS = %w[
      host upgrade connection sec-websocket-key sec-websocket-version sec-websocket-accept
    ].freeze

    attr_reader :socket, :capabilities, :response_headers

    def initialize(uri, headers: {}, timeout: 30)
      @uri = URI(uri)
      unless %w[ws wss].include?(@uri.scheme) && @uri.host
        raise ArgumentError, "WebSocket URI must use ws or wss and include a host"
      end

      @headers = headers.to_h
      validate_request_headers!
      @timeout = Float(timeout)
      raise ArgumentError, "timeout must be > 0" unless @timeout.positive? && @timeout.finite?
      @read_mutex = Mutex.new
      @write_mutex = Mutex.new
      @state_mutex = Mutex.new
      @closed = false
      @capabilities = {}
      @response_headers = {}
    end

    # 建立 TCP/SSL 连接并完成 WebSocket 握手
    # @return [self]
    def connect!
      @state_mutex.synchronize do
        raise Error, "WebSocket connection is closed" if @closed
        raise Error, "WebSocket connection already started" if @socket
      end

      @socket = create_socket
      perform_handshake
      parse_capabilities
      self
    rescue StandardError
      close_socket
      raise
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
      payload = build_close_payload(code, reason)
      write_frame(0x08, payload)
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    # 读取下一条消息
    # @return [Array(Symbol, String), nil] [:text, data] / [:binary, data] / [:close, data] / nil
    def read_message
      @read_mutex.synchronize do
        return nil if closed?

        read_frame
      end
    end

    # 优雅关闭：发送 close 帧后关闭 socket
    def close
      @write_mutex.synchronize do
        return if closed?

        begin
          write_frame_unlocked(0x08, [1000].pack("n")) if @socket && !@socket.closed?
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        ensure
          mark_closed
        end
      end
      close_socket
    end

    def closed?
      @state_mutex.synchronize { @closed }
    end

    private

    # 创建底层 socket（TCP 或 TLS-wrapped）
    def create_socket
      port = @uri.port || (@uri.scheme == "wss" ? 443 : 80)
      tcp = Socket.tcp(
        @uri.host,
        port,
        connect_timeout: @timeout,
        resolv_timeout: @timeout
      )
      tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, 1)

      if @uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        # set_params 会自动加载系统 CA 证书
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.sync_close = true
        ssl.hostname = @uri.host
        connect_ssl(ssl)
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
      request += "Host: #{host_header}\r\n"
      request += "Upgrade: websocket\r\n"
      request += "Connection: Upgrade\r\n"
      request += "Sec-WebSocket-Key: #{key}\r\n"
      request += "Sec-WebSocket-Version: 13\r\n"
      @headers.each { |k, v| request += "#{k}: #{v}\r\n" }
      request += "\r\n"

      deadline = monotonic_now + @timeout
      write_all(request, deadline: deadline)

      # 读取 HTTP 响应头
      response = ""
      loop do
        line = read_line(deadline: deadline)
        response += line
        raise Error, "WebSocket handshake headers too large" if response.bytesize > MAX_HANDSHAKE_BYTES
        break if line == "\r\n"
      end

      lines = response.split("\r\n")
      status_match = lines.shift&.match(/\AHTTP\/\d(?:\.\d)?\s+(\d{3})(?:\s|\z)/)
      status = status_match&.[](1)
      unless status == "101"
        raise Error, "WebSocket handshake failed (HTTP #{status})"
      end

      lines.each do |line|
        if (m = line.match(/\A([^:]+):\s*(.*)\z/))
          @response_headers[m[1].downcase] = m[2]
        end
      end

      unless @response_headers["upgrade"].to_s.casecmp?("websocket") &&
             @response_headers["connection"].to_s.split(",").any? { |token| token.strip.casecmp?("upgrade") }
        raise Error, "WebSocket handshake missing upgrade headers"
      end

      expected_accept = Base64.strict_encode64(Digest::SHA1.digest("#{key}#{WEBSOCKET_GUID}"))
      unless secure_compare(@response_headers["sec-websocket-accept"].to_s, expected_accept)
        raise Error, "WebSocket handshake has invalid Sec-WebSocket-Accept"
      end
    end

    # 从 X-Sprite-Capabilities 头解析服务端能力（如 signal）
    def parse_capabilities
      if (caps = @response_headers["x-sprite-capabilities"])
        caps.split(",").each { |c| @capabilities[c.strip] = true }
      end
    end

    def read_line(deadline: nil)
      line = +""
      loop do
        ch = read_exact(1, deadline: deadline)
        raise Error, "Connection closed during handshake" unless ch

        line << ch
        raise Error, "WebSocket handshake line too large" if line.bytesize > MAX_HANDSHAKE_LINE_BYTES
        break if line.end_with?("\n")
      end
      line
    end

    # 写入一个 WebSocket 帧（客户端帧必须 mask）
    def write_frame(opcode, payload)
      @write_mutex.synchronize do
        return if closed?

        write_frame_unlocked(opcode, payload)
      end
    end

    def write_frame_unlocked(opcode, payload)
      payload = payload.b
      raise Error, "WebSocket frame exceeds #{MAX_FRAME_PAYLOAD_BYTES} bytes" if payload.bytesize > MAX_FRAME_PAYLOAD_BYTES
      raise Error, "WebSocket control frame exceeds 125 bytes" if opcode >= 0x08 && payload.bytesize > 125
      raise Error, "WebSocket is not connected" unless @socket

      frame = +[0x80 | opcode].pack("C")
      mask_key = SecureRandom.random_bytes(4)
      length = payload.bytesize
      if length < 126
        frame << [0x80 | length].pack("C")
      elsif length < 65_536
        frame << [0x80 | 126, length].pack("Cn")
      else
        frame << [0x80 | 127, length].pack("CQ>")
      end
      frame << mask_key
      frame << mask(payload, mask_key)
      write_all(frame, deadline: monotonic_now + WS_WRITE_WAIT)
    end

    # 读取一个完整 WebSocket message，支持 fragmentation，并就地处理 control frames。
    def read_frame
      message_opcode = nil
      message = +"".b

      loop do
        header = read_frame_header
        return unless header

        fin, opcode, length = header
        payload = length.zero? ? +"".b : read_exact(length)
        raise Error, "WebSocket frame truncated" unless payload&.bytesize == length

        if opcode >= 0x08
          raise Error, "fragmented WebSocket control frame" unless fin
          raise Error, "WebSocket control frame exceeds 125 bytes" if length > 125

          case opcode
          when 0x08
            validate_received_close_payload!(payload)
            write_frame(0x08, payload) unless closed?
            mark_closed
            close_socket
            return [:close, payload]
          when 0x09
            write_frame(0x0A, payload)
          when 0x0A
            nil
          else
            raise Error, format("unsupported WebSocket control opcode 0x%02x", opcode)
          end
          next
        end

        case opcode
        when 0x00
          raise Error, "unexpected WebSocket continuation frame" unless message_opcode
        when 0x01, 0x02
          raise Error, "interleaved fragmented WebSocket message" if message_opcode
          message_opcode = opcode
        else
          raise Error, format("unsupported WebSocket opcode 0x%02x", opcode)
        end

        message << payload
        if message.bytesize > MAX_FRAME_PAYLOAD_BYTES
          raise Error, "WebSocket message exceeds #{MAX_FRAME_PAYLOAD_BYTES} bytes"
        end
        next unless fin

        if message_opcode == 0x01
          text = message.force_encoding(Encoding::UTF_8)
          raise Error, "WebSocket text frame is not valid UTF-8" unless text.valid_encoding?

          return [:text, text]
        end
        return [:binary, message]
      end
    rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError
      mark_closed
      nil
    rescue Sprites::Error
      close_socket
      raise
    end

    def read_frame_header
      bytes = read_exact(2)
      return unless bytes
      raise Error, "WebSocket frame header truncated" unless bytes.bytesize == 2

      first, second = bytes.unpack("CC")
      raise Error, "WebSocket RSV bits are not supported" unless (first & 0x70).zero?
      raise Error, "server WebSocket frames must not be masked" unless (second & 0x80).zero?

      fin = (first & 0x80) != 0
      opcode = first & 0x0F
      length = second & 0x7F
      if length == 126
        extended = read_exact(2)
        raise Error, "WebSocket frame length truncated" unless extended&.bytesize == 2
        length = extended.unpack1("n")
      elsif length == 127
        extended = read_exact(8)
        raise Error, "WebSocket frame length truncated" unless extended&.bytesize == 8
        raise Error, "invalid WebSocket 64-bit frame length" unless (extended.getbyte(0) & 0x80).zero?
        length = extended.unpack1("Q>")
      end
      raise Error, "WebSocket frame exceeds #{MAX_FRAME_PAYLOAD_BYTES} bytes" if length > MAX_FRAME_PAYLOAD_BYTES

      [fin, opcode, length]
    end

    def connect_ssl(ssl)
      deadline = monotonic_now + @timeout
      loop do
        result = ssl.connect_nonblock(exception: false)
        return ssl if result.equal?(ssl)

        case result
        when :wait_readable
          wait_for_io(ssl, :read, deadline: deadline, error_class: Net::OpenTimeout)
        when :wait_writable
          wait_for_io(ssl, :write, deadline: deadline, error_class: Net::OpenTimeout)
        else
          return ssl
        end
      end
    end

    def read_exact(length, deadline: nil)
      buffer = String.new(capacity: length, encoding: Encoding::BINARY)
      while buffer.bytesize < length
        chunk = @socket.read_nonblock(length - buffer.bytesize, exception: false)
        case chunk
        when :wait_readable
          wait_for_io(@socket, :read, deadline: deadline)
        when :wait_writable
          wait_for_io(@socket, :write, deadline: deadline)
        when nil
          return buffer.empty? ? nil : buffer
        else
          buffer << chunk
        end
      end
      buffer
    end

    def write_all(data, deadline: nil)
      offset = 0
      while offset < data.bytesize
        written = @socket.write_nonblock(data.byteslice(offset..), exception: false)
        case written
        when :wait_readable
          wait_for_io(@socket, :read, deadline: deadline, error_class: Net::WriteTimeout)
        when :wait_writable
          wait_for_io(@socket, :write, deadline: deadline, error_class: Net::WriteTimeout)
        else
          offset += written
        end
      end
      offset
    end

    def wait_for_io(io, direction, deadline:, error_class: Net::ReadTimeout)
      timeout = deadline && (deadline - monotonic_now)
      raise error_class, "WebSocket I/O timed out" if timeout && timeout <= 0

      ready = direction == :read ? io.wait_readable(timeout) : io.wait_writable(timeout)
      raise error_class, "WebSocket I/O timed out" unless ready
    end

    def mask(payload, key)
      key_bytes = key.bytes
      result = String.new(capacity: payload.bytesize, encoding: Encoding::BINARY)
      payload.each_byte.with_index do |byte, index|
        result << (byte ^ key_bytes[index & 3])
      end
      result
    end

    def secure_compare(actual, expected)
      return false unless actual.bytesize == expected.bytesize

      difference = 0
      actual.bytes.zip(expected.bytes) { |left, right| difference |= left ^ right }
      difference.zero?
    end

    def validate_request_headers!
      @headers.each do |name, value|
        normalized = name.to_s.downcase
        unless name.to_s.match?(/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/)
          raise ArgumentError, "invalid WebSocket request header name"
        end
        if RESERVED_REQUEST_HEADERS.include?(normalized)
          raise ArgumentError, "reserved WebSocket request header: #{name}"
        end
        if value.to_s.match?(/[\r\n]/)
          raise ArgumentError, "invalid WebSocket request header value"
        end
      end
    end

    def host_header
      host = @uri.host
      host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
      default_port = @uri.scheme == "wss" ? 443 : 80
      @uri.port == default_port ? host : "#{host}:#{@uri.port}"
    end

    def build_close_payload(code, reason)
      code = Integer(code)
      reason = reason.to_s.encode(Encoding::UTF_8)
      raise ArgumentError, "invalid WebSocket close code" unless valid_close_code?(code)
      raise ArgumentError, "WebSocket close reason exceeds 123 bytes" if reason.bytesize > 123

      [code].pack("n") + reason
    end

    def validate_received_close_payload!(payload)
      raise Error, "invalid WebSocket close payload length" if payload.bytesize == 1
      return if payload.empty?

      code = payload.unpack1("n")
      raise Error, "invalid WebSocket close code #{code}" unless valid_close_code?(code)

      reason = payload.byteslice(2..).force_encoding(Encoding::UTF_8)
      raise Error, "WebSocket close reason is not valid UTF-8" unless reason.valid_encoding?
    end

    def valid_close_code?(code)
      (code.between?(1000, 1014) && ![1004, 1005, 1006].include?(code)) ||
        code.between?(3000, 4999)
    end

    def mark_closed
      @state_mutex.synchronize { @closed = true }
    end

    def close_socket
      @socket&.close unless @socket&.closed?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      mark_closed
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
