# frozen_string_literal: true

require "net/http"

module Sprites
  # 有界、thread-safe 的 Net::HTTP keep-alive 连接池。
  #
  # 一个 Net::HTTP session 同一时刻只能处理一个请求。池在连接级别独占，允许
  # Puma threads 与安装了 Fiber scheduler 的 non-blocking Fibers 并行等待 I/O，
  # 同时避免为每个请求重新握手。SDK 不创建 thread、Fiber 或 scheduler。
  class HTTPTransport
    DEFAULT_MAX_CONNECTIONS = 8

    attr_reader :max_connections

    def initialize(base_url:, max_connections: DEFAULT_MAX_CONNECTIONS, timeout: 30, connection_factory: nil)
      @base_uri = URI(base_url)
      @max_connections = Integer(max_connections)
      raise ArgumentError, "max_connections must be >= 1" if @max_connections < 1

      @timeout = timeout
      @connection_factory = connection_factory || method(:build_connection)
      @mutex = Mutex.new
      @available = []
      @connections = {}.compare_by_identity
      @pending = 0
      @condition = ConditionVariable.new
      @closed = false
      @pid = Process.pid
    end

    def request(uri, request, read_timeout: nil, open_timeout: nil, write_timeout: nil)
      validate_origin!(uri)
      connection = checkout
      reusable = false

      begin
        response = with_timeouts(connection, read_timeout:, open_timeout:, write_timeout:) do
          connection.request(request)
        end
        reusable = reusable?(connection, response)
        response
      ensure
        reusable ? checkin(connection) : discard(connection)
      end
    end

    # 在调用线程内消费 response body，保留 Net::HTTP#read_body 交付的 chunk 边界。
    # 适用于 HTTP exec 这类不能把 response 交给池外异步消费的协议。
    def request_stream(uri, request, read_timeout: nil, open_timeout: nil, write_timeout: nil)
      raise ArgumentError, "block is required" unless block_given?

      validate_origin!(uri)
      connection = checkout
      response = nil
      result = nil
      reusable = false

      begin
        with_timeouts(connection, read_timeout:, open_timeout:, write_timeout:) do
          connection.request(request) do |current_response|
            response = current_response
            result = yield current_response
          end
        end
        reusable = reusable?(connection, response)
        result
      ensure
        reusable ? checkin(connection) : discard(connection)
      end
    end

    def connection_count
      @mutex.synchronize do
        reset_after_fork!
        @connections.size
      end
    end

    def close
      connections = @mutex.synchronize do
        return if @closed

        @closed = true
        snapshot = @connections.keys
        @connections.clear
        @available.clear
        @condition.broadcast
        snapshot
      end

      connections.each { |connection| close_connection(connection) }
      nil
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    private

    def checkout
      loop do
        create = @mutex.synchronize do
          reset_after_fork!
          raise Error, "client is closed" if @closed

          if (connection = @available.pop)
            return connection
          end

          if @connections.size + @pending < @max_connections
            @pending += 1
            true
          else
            @condition.wait(@mutex)
            false
          end
        end

        next unless create

        begin
          connection = @connection_factory.call(@base_uri, @timeout)
        rescue StandardError
          @mutex.synchronize do
            @pending -= 1
            @condition.signal
          end
          raise
        end

        accepted = @mutex.synchronize do
          @pending -= 1
          unless @closed
            @connections[connection] = true
            @condition.signal
            true
          end
        end

        return connection if accepted

        close_connection(connection)
        raise Error, "client is closed"
      end
    end

    def checkin(connection)
      close = @mutex.synchronize do
        if @closed || !@connections.key?(connection)
          true
        else
          @available << connection
          @condition.signal
          false
        end
      end
      close_connection(connection) if close
    end

    def discard(connection)
      removed = @mutex.synchronize do
        deleted = @connections.delete(connection)
        @available.delete(connection)
        @condition.signal if deleted
        deleted
      end
      close_connection(connection) if removed || connection
    end

    def with_timeouts(connection, read_timeout:, open_timeout:, write_timeout:)
      previous_read = connection.read_timeout if read_timeout && connection.respond_to?(:read_timeout)
      previous_open = connection.open_timeout if open_timeout && connection.respond_to?(:open_timeout)
      previous_write = connection.write_timeout if write_timeout && connection.respond_to?(:write_timeout)
      connection.read_timeout = read_timeout if read_timeout && connection.respond_to?(:read_timeout=)
      connection.open_timeout = open_timeout if open_timeout && connection.respond_to?(:open_timeout=)
      connection.write_timeout = write_timeout if write_timeout && connection.respond_to?(:write_timeout=)
      yield
    ensure
      if read_timeout && connection.respond_to?(:read_timeout=)
        connection.read_timeout = previous_read
      end
      if open_timeout && connection.respond_to?(:open_timeout=)
        connection.open_timeout = previous_open
      end
      if write_timeout && connection.respond_to?(:write_timeout=)
        connection.write_timeout = previous_write
      end
    end

    def reusable?(connection, response)
      return false if response["Connection"].to_s.casecmp?("close")
      return connection.started? if connection.respond_to?(:started?)

      true
    end

    def build_connection(uri, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = timeout
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      http.start
      http
    end

    def close_connection(connection)
      return unless connection
      return if connection.respond_to?(:started?) && !connection.started?

      connection.finish if connection.respond_to?(:finish)
    rescue IOError, SystemCallError
      nil
    end

    def validate_origin!(uri)
      return if uri.scheme == @base_uri.scheme && uri.host == @base_uri.host && uri.port == @base_uri.port

      raise ArgumentError, "request URI origin does not match client base_url"
    end

    # Puma cluster 在 preload 后 fork。正常路径会在 worker 内懒创建 Client；若调用方
    # 提前创建但尚未使用，仍将继承的空闲 descriptor 在 child 中关闭后重置。
    def reset_after_fork!
      return if @pid == Process.pid

      stale = @connections.keys
      @available.clear
      @connections.clear
      @pending = 0
      @pid = Process.pid
      stale.each { |connection| close_connection(connection) }
    end
  end
end
