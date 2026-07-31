# frozen_string_literal: true

require "net/http"

module Sprites
  # 以独占 Net::HTTP connection 承载一个 streaming response。
  #
  # Net::HTTP 只允许在 request block 内增量读取 body，因此由一个 producer thread
  # 驱动网络读取，通过 IO.pipe 提供有界 backpressure。close 会关闭 pipe 与 socket，
  # 不让未消费的 checkpoint/service/watch 流长期占用 provider connection。
  class HTTPStreamResponse
    attr_reader :body

    def initialize(uri:, request:, timeout:, on_release: nil, connection_factory: nil)
      @uri = uri
      @request = request
      @timeout = timeout
      @on_release = on_release
      @connection_factory = connection_factory || method(:build_connection)
      @ready = Queue.new
      @reader, @writer = IO.pipe
      @body = Body.new(@reader, self)
      @mutex = Mutex.new
      @headers = {}
      @code = nil
      @http = nil
      @thread = nil
      @started = false
      @closed = false
      @released = false
    end

    def start
      @mutex.synchronize do
        raise Error, "stream is closed" if @closed
        raise Error, "stream already started" if @started

        @started = true
        @thread = Thread.new { produce }
        @thread.report_on_exception = false
      end

      result = @ready.pop
      raise result if result.is_a?(Exception)

      self
    rescue StandardError
      close
      raise
    end

    def code
      @mutex.synchronize { @code }
    end

    def [](name)
      @mutex.synchronize { @headers[name.to_s.downcase] }
    end

    def connection_open?
      @mutex.synchronize { !@http.nil? }
    end

    def close
      thread, http, release = @mutex.synchronize do
        return if @closed

        @closed = true
        current_thread = @thread
        current_http = @http
        @http = nil
        [current_thread, current_http, mark_released!]
      end

      close_io(@reader)
      close_io(@writer)
      close_connection(http)
      join_producer(thread)
      release&.call
      nil
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    class Body
      def initialize(reader, response)
        @reader = reader
        @response = response
        @mutex = Mutex.new
        @error = nil
      end

      def gets(*args)
        value = @reader.gets(*args)
        raise_producer_error! if value.nil?
        value
      end

      def read(*args)
        value = @reader.read(*args)
        raise_producer_error! if args.empty? || value.nil?
        value
      end

      def each_line(&block)
        return enum_for(:each_line) unless block

        while (line = gets)
          yield line
        end
      ensure
        close
      end

      def close
        @response.close
      end

      def closed? = @reader.closed?

      def fail!(error)
        @mutex.synchronize { @error ||= error }
      end

      private

      def raise_producer_error!
        error = @mutex.synchronize { @error }
        raise error if error
      end
    end

    private

    def produce
      http = @connection_factory.call(@uri, @timeout)
      @mutex.synchronize do
        raise Error, "stream is closed" if @closed

        @http = http
      end

      http.request(@request) do |response|
        publish_headers(response)
        response.read_body { |chunk| @writer.write(chunk) }
      end
    rescue StandardError => e
      if headers_published?
        @body.fail!(e) unless closed?
      else
        @ready << e
      end
    ensure
      close_io(@writer)
      close_connection(http)
      release_producer
    end

    def publish_headers(response)
      headers = {}
      response.each_header { |name, value| headers[name.downcase] = value }
      @mutex.synchronize do
        @code = response.code
        @headers = headers
      end
      @ready << true
    end

    def headers_published?
      @mutex.synchronize { !@code.nil? }
    end

    def release_producer
      @mutex.synchronize do
        @http = nil
        @thread = nil if Thread.current.equal?(@thread)
      end
    end

    def mark_released!
      return if @released

      @released = true
      @on_release
    end

    def build_connection(uri, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      http.start
      http
    end

    def close_connection(http)
      return unless http
      return if http.respond_to?(:started?) && !http.started?

      http.finish if http.respond_to?(:finish)
    rescue IOError, SystemCallError
      nil
    end

    def close_io(io)
      io.close unless io.closed?
    rescue IOError, SystemCallError
      nil
    end

    def join_producer(thread)
      return unless thread&.alive?
      return if thread.equal?(Thread.current)

      thread.join(1)
      return unless thread.alive?

      thread.kill
      thread.join
    end
  end
end
