# frozen_string_literal: true

# 端口转发与 TCP 代理
#
# 通过 WebSocket 隧道将本地端口转发到 sprite 内的端口。
# 支持单端口、多端口、以及原始 TCP socket 代理。
#
# @example 单端口转发
#   session = sprite.proxy_port(3000, 3000)
#   # 现在 localhost:3000 连接到 sprite 的 3000 端口
#   session.close

require "socket"
require "json"
require "io/wait"

module Sprites
  module Proxy
    def proxy_socket(network, sprite_name, addr)
      case network
      when "tcp"
        begin
          ws_conn = dial_proxy_websocket(sprite_name)
          connection = init_socket_tcp(ws_conn, addr)
          connection.on_close = -> { untrack_connection(connection) }
          track_connection(connection)
        rescue StandardError
          connection&.close
          ws_conn&.close
          raise
        end
      else
        raise Error, "unsupported network type: #{network}"
      end
    end

    def proxy_port(sprite_name, local_port, remote_port)
      mapping = PortMapping.new(local_port: local_port, remote_port: remote_port)
      sessions = proxy_ports(sprite_name, [mapping])
      sessions.first
    end

    def proxy_ports(sprite_name, mappings)
      sessions = []

      mappings.each do |mapping|
        begin
          session = create_proxy_session(sprite_name, mapping)
          sessions << session
        rescue => e
          sessions.each(&:close)
          raise Error, "failed to create proxy for port #{mapping.local_port}: #{e.message}"
        end
      end

      sessions
    end

    private

    def dial_proxy_websocket(sprite_name)
      ws_url = build_proxy_url(sprite_name)

      headers = ClientSignals.auth_headers(
        @token,
        "Sprite-Client-Features" => "control"
      )

      WebSocketConnection.new(ws_url, headers: headers, timeout: 30).connect!
    end

    def build_proxy_url(sprite_name)
      Routes.websocket_uri(@base_url, Routes.proxy(sprite_name)).to_s
    end

    def init_socket_tcp(ws_conn, addr)
      host, port = parse_proxy_addr(addr)

      init_msg = { host: host, port: port }
      ws_conn.write_text(JSON.generate(init_msg))

      msg = ws_conn.read_message
      raise Error, "failed to read proxy response" unless msg

      type, data = msg
      raise Error, "unexpected proxy response frame: #{type}" unless type == :text

      response = JSON.parse(data)
      raise Error, "unexpected proxy status: #{response['status']}" unless response["status"] == "connected"

      ProxyConn.new(ws_conn, response["target"])
    rescue StandardError
      ws_conn&.close
      raise
    end

    def parse_proxy_addr(addr)
      value = addr.to_s
      if (match = value.match(/\A\[([^\]]+)\]:(\d+)\z/))
        host = match[1]
        port_str = match[2]
      else
        host, separator, port_str = value.rpartition(":")
        if separator.empty? || host.include?(":")
          raise Error, "invalid address: #{addr}"
        end
      end

      port = Integer(port_str, exception: false)
      raise Error, "invalid port in address: #{addr}" unless port&.between?(1, 65_535)

      host = "localhost" if host.empty?
      [host, port]
    end

    def create_proxy_session(sprite_name, mapping)
      local_port = Integer(mapping.local_port)
      remote_port = Integer(mapping.remote_port)
      raise ArgumentError, "local_port must be between 0 and 65535" unless local_port.between?(0, 65_535)
      raise ArgumentError, "remote_port must be between 1 and 65535" unless remote_port.between?(1, 65_535)

      server = TCPServer.new("127.0.0.1", local_port)

      session = ProxySession.new(
        local_port: local_port,
        remote_port: remote_port,
        remote_host: mapping.remote_host,
        listener: server,
        client: self,
        sprite_name: sprite_name,
        on_close: -> { untrack_connection(session) }
      )

      track_connection(session)
      session.start_accept_loop
      session
    rescue StandardError
      session&.close
      server&.close
      raise
    end
  end

  class ProxyConn
    attr_reader :remote_target
    attr_accessor :on_close

    def initialize(ws_conn, target)
      @ws_conn = ws_conn
      @remote_target = target
      @read_mutex = Mutex.new
      @write_mutex = Mutex.new
      @state_mutex = Mutex.new
      @closed = false
      @released = false
      @read_buffer = +""
    end

    def read(length)
      length = Integer(length)
      raise ArgumentError, "length must be >= 0" if length.negative?
      return +"".b if length.zero?

      @read_mutex.synchronize do
        while @read_buffer.empty?
          msg = @ws_conn.read_message
          unless msg
            close
            return nil
          end

          msg_type, data = msg
          if msg_type == :close
            close
            return nil
          end
          next unless msg_type == :binary

          @read_buffer << data
        end

        @read_buffer.slice!(0, [length, @read_buffer.bytesize].min)
      end
    end

    def write(data)
      @write_mutex.synchronize do
        raise IOError, "closed proxy connection" if closed?

        @ws_conn.write_binary(data)
        data.bytesize
      end
    end

    def close
      release = @state_mutex.synchronize do
        return if @closed && @released

        @closed = true
        next if @released

        @released = true
        @on_close
      end
      @ws_conn.close
    rescue StandardError
      nil
    ensure
      release&.call
    end

    def closed?
      @state_mutex.synchronize { @closed }
    end

    def connection_open? = !closed?
  end

  class ProxySession
    attr_reader :local_port, :remote_port, :remote_host

    def initialize(local_port:, remote_port:, remote_host:, listener:, client:, sprite_name:, on_close: nil)
      @local_port = local_port
      @remote_port = remote_port
      @remote_host = remote_host || "localhost"
      @listener = listener
      @client = client
      @sprite_name = sprite_name
      @closed = false
      @close_mutex = Mutex.new
      @accept_thread = nil
      @connections = {}.compare_by_identity
      @handler_threads = {}.compare_by_identity
      @on_close = on_close
      @released = false
    end

    def start_accept_loop
      @close_mutex.synchronize do
        raise Error, "proxy session is closed" if @closed
        raise Error, "proxy session already started" if @accept_thread

        @accept_thread = Thread.new { accept_loop }
        @accept_thread.report_on_exception = false
      end
      self
    end

    def close
      listener, accept_thread, connections, handlers, release = @close_mutex.synchronize do
        return if @closed

        @closed = true
        snapshot = @connections.flat_map { |local, remote| [local, remote] }.compact
        [@listener, @accept_thread, snapshot, @handler_threads.keys, release_callback]
      end

      close_io(listener)
      connections.each { |connection| close_io(connection) }
      join_owned_thread(accept_thread)
      handlers.each { |thread| join_owned_thread(thread) }
      nil
    ensure
      release&.call
    end

    def local_addr
      @listener&.local_address
    end

    def wait
      @accept_thread&.join
    end

    def closed?
      @close_mutex.synchronize { @closed }
    end

    def connection_open? = !closed?

    private

    def accept_loop
      loop do
        break if @closed

        begin
          conn = @listener.accept
        rescue IOError, Errno::EBADF
          break
        end

        @close_mutex.synchronize do
          if @closed
            close_io(conn)
            break
          end

          @connections[conn] = nil
          thread = Thread.new(conn) { |local| handle_connection(local) }
          thread.report_on_exception = false
          @handler_threads[thread] = true
        end
      end
    rescue => e
      Sprites.dbg("sprites: proxy accept error", error: e.message)
    end

    def handle_connection(local_conn)
      addr = "#{@remote_host}:#{@remote_port}"

      ws_conn = @client.send(:dial_proxy_websocket, @sprite_name)
      remote_conn = @client.send(:init_socket_tcp, ws_conn, addr)
      closed = @close_mutex.synchronize do
        if @closed
          true
        else
          @connections[local_conn] = remote_conn
          false
        end
      end
      return if closed

      remote_reader = Thread.new do
        copy_stream_from_proxy(remote_conn, local_conn)
        close_io(local_conn)
      end
      remote_reader.report_on_exception = false

      copy_stream(local_conn, remote_conn)
      close_io(remote_conn)
      join_owned_thread(remote_reader)
    rescue => e
      Sprites.dbg("sprites: proxy connection error", error: e.message)
    ensure
      close_io(remote_conn)
      close_io(local_conn)
      join_owned_thread(remote_reader)
      @close_mutex.synchronize do
        @connections.delete(local_conn)
        @handler_threads.delete(Thread.current)
      end
    end

    def copy_stream(from_io, to_proxy)
      buf = String.new(capacity: 32768)
      loop do
        data = from_io.read_nonblock(32768, buf, exception: false)
        case data
        when :wait_readable
          from_io.wait_readable(1)
        when nil
          break
        else
          to_proxy.write(data)
        end
      end
    rescue IOError, Errno::ECONNRESET
      # connection closed
    end

    def copy_stream_from_proxy(from_proxy, to_io)
      loop do
        data = from_proxy.read(32768)
        break unless data

        to_io.write(data)
      end
    rescue IOError, Errno::ECONNRESET
      # connection closed
    end

    def release_callback
      return if @released

      @released = true
      @on_close
    end

    def close_io(io)
      io&.close unless io&.closed?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    def join_owned_thread(thread)
      return unless thread&.alive? && !thread.equal?(Thread.current)

      thread.join(1)
      return unless thread.alive?

      thread.kill
      thread.join
    end
  end

  class ProxyManager
    def initialize
      @sessions = []
      @mutex = Mutex.new
    end

    def add_session(session)
      @mutex.synchronize { @sessions << session }
    end

    def close_all
      @mutex.synchronize do
        @sessions.each(&:close)
        @sessions.clear
      end
    end

    def wait_all
      sessions = @mutex.synchronize { @sessions.dup }
      sessions.each(&:wait)
    end
  end

  class Sprite
    def proxy_socket(network, addr)
      client.proxy_socket(network, name, addr)
    end

    def proxy_port(local_port, remote_port)
      client.proxy_port(name, local_port, remote_port)
    end

    def proxy_ports(mappings)
      client.proxy_ports(name, mappings)
    end
  end
end
