# frozen_string_literal: true

require "socket"
require "json"

module Sprites
  module Proxy
    def proxy_socket(network, sprite_name, addr)
      case network
      when "tcp"
        ws_conn = dial_proxy_websocket(sprite_name)
        init_socket_tcp(ws_conn, addr)
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

      headers = {
        "Authorization" => "Bearer #{@token}",
        "User-Agent" => "sprites-ruby-sdk/#{VERSION}",
        "Sprite-Client-Features" => "control"
      }

      WebSocketConnection.new(ws_url, headers: headers, timeout: 30).connect!
    end

    def build_proxy_url(sprite_name)
      base = @base_url.sub(/\Ahttp/, "ws")
      "#{base}/v1/sprites/#{sprite_name}/proxy"
    end

    def init_socket_tcp(ws_conn, addr)
      host, port = parse_proxy_addr(addr)

      init_msg = { host: host, port: port }
      ws_conn.write_text(JSON.generate(init_msg))

      msg = ws_conn.read_message
      raise Error, "failed to read proxy response" unless msg

      _, data = msg
      response = JSON.parse(data)
      raise Error, "unexpected proxy status: #{response['status']}" unless response["status"] == "connected"

      ProxyConn.new(ws_conn, response["target"])
    end

    def parse_proxy_addr(addr)
      host, port_str = addr.split(":", 2)
      raise Error, "invalid address: #{addr}" unless port_str

      port = port_str.to_i
      raise Error, "invalid port in address: #{addr}" if port < 1 || port > 65535

      host = "localhost" if host.empty?
      [host, port]
    end

    def create_proxy_session(sprite_name, mapping)
      server = TCPServer.new("localhost", mapping.local_port)

      session = ProxySession.new(
        local_port: mapping.local_port,
        remote_port: mapping.remote_port,
        remote_host: mapping.remote_host,
        listener: server,
        client: self,
        sprite_name: sprite_name
      )

      session.start_accept_loop
      session
    end
  end

  class ProxyConn
    attr_reader :remote_target

    def initialize(ws_conn, target)
      @ws_conn = ws_conn
      @remote_target = target
      @read_mutex = Mutex.new
      @write_mutex = Mutex.new
      @closed = false
      @read_buffer = +""
    end

    def read(length)
      @read_mutex.synchronize do
        while @read_buffer.bytesize < length
          msg = @ws_conn.read_message
          return nil unless msg

          msg_type, data = msg
          next unless msg_type == :binary

          @read_buffer << data
        end

        @read_buffer.slice!(0, length)
      end
    end

    def write(data)
      @write_mutex.synchronize do
        @ws_conn.write_binary(data)
        data.bytesize
      end
    end

    def close
      return if @closed

      @closed = true
      @ws_conn.close rescue nil
    end

    def closed?
      @closed
    end
  end

  class ProxySession
    attr_reader :local_port, :remote_port, :remote_host

    def initialize(local_port:, remote_port:, remote_host:, listener:, client:, sprite_name:)
      @local_port = local_port
      @remote_port = remote_port
      @remote_host = remote_host || "localhost"
      @listener = listener
      @client = client
      @sprite_name = sprite_name
      @closed = false
      @close_mutex = Mutex.new
      @accept_thread = nil
    end

    def start_accept_loop
      @accept_thread = Thread.new { accept_loop }
    end

    def close
      @close_mutex.synchronize do
        return if @closed

        @closed = true
        @listener&.close rescue nil
        @accept_thread&.kill rescue nil
      end
    end

    def local_addr
      @listener&.local_address
    end

    def wait
      @accept_thread&.join
    end

    private

    def accept_loop
      loop do
        break if @closed

        begin
          conn = @listener.accept
        rescue IOError, Errno::EBADF
          break
        end

        Thread.new(conn) { |c| handle_connection(c) }
      end
    rescue => e
      Sprites.dbg("sprites: proxy accept error", error: e.message)
    end

    def handle_connection(local_conn)
      addr = "#{@remote_host}:#{@remote_port}"

      ws_conn = @client.send(:dial_proxy_websocket, @sprite_name)
      remote_conn = @client.send(:init_socket_tcp, ws_conn, addr)

      t1 = Thread.new do
        copy_stream(local_conn, remote_conn)
        remote_conn.close rescue nil
      end

      t2 = Thread.new do
        copy_stream_from_proxy(remote_conn, local_conn)
        local_conn.close rescue nil
      end

      t1.join
      t2.join
    rescue => e
      Sprites.dbg("sprites: proxy connection error", error: e.message)
    ensure
      local_conn&.close rescue nil
    end

    def copy_stream(from_io, to_proxy)
      buf = String.new(capacity: 32768)
      loop do
        data = from_io.read_nonblock(32768, buf, exception: false)
        case data
        when :wait_readable
          IO.select([from_io], nil, nil, 1)
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
