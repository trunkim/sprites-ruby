# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe "Ruby 4 real HTTP transport integration" do
  class ScriptedHTTPServer
    attr_reader :port, :request_line, :headers, :body

    def initialize(&handler)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.local_address.ip_port
      @thread = Thread.new do
        socket = @server.accept
        @socket = socket
        @request_line, @headers, @body = read_request(socket)
        handler.call(socket, self)
      rescue IOError, Errno::EBADF
        nil
      ensure
        socket&.close unless socket&.closed?
      end
      @thread.report_on_exception = false
    end

    def join
      @thread.value
    end

    def close
      @socket&.close unless @socket&.closed?
      @server.close unless @server.closed?
      @thread.join(1)
      @thread.kill if @thread.alive?
      @thread.join
    rescue IOError, SystemCallError
      nil
    end

    private

    def read_request(socket)
      request_line = socket.gets&.strip
      headers = {}
      while (line = socket.gets)
        break if line == "\r\n"

        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      length = headers.fetch("content-length", "0").to_i
      body = length.positive? ? socket.read(length) : +""
      [request_line, headers, body]
    end
  end

  # allow_net_connect! 仍会经过 WebMock adapter，并重分块/缓冲 Net::HTTP body；
  # 这里验证的正是原生 transport 行为，因此测试期间完全卸载 adapter。
  before { WebMock.disable! }
  after do
    WebMock.enable!
    WebMock.disable_net_connect!
  end

  it "uses two real keep-alive sockets concurrently and enforces the configured cap" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    state = { active: 0, peak: 0, completed: 0 }
    mutex = Mutex.new
    handlers = []
    acceptor = Thread.new do
      2.times do
        socket = server.accept
        handlers << Thread.new do
          loop do
            request_line = socket.gets
            break unless request_line

            while (header_line = socket.gets)
              break if header_line == "\r\n"
            end
            mutex.synchronize do
              state[:active] += 1
              state[:peak] = [state[:peak], state[:active]].max
            end
            sleep 0.03
            socket.write(
              "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n" \
              "Connection: keep-alive\r\n\r\nok"
            )
            mutex.synchronize do
              state[:active] -= 1
              state[:completed] += 1
            end
          end
        ensure
          socket.close unless socket.closed?
        end
        handlers.last.report_on_exception = false
      end
      handlers.each(&:join)
    rescue IOError, Errno::EBADF
      nil
    end
    acceptor.report_on_exception = false
    base_url = "http://127.0.0.1:#{port}"
    transport = Sprites::HTTPTransport.new(base_url:, max_connections: 2)
    uri = URI("#{base_url}/v1/sprites")
    gate = Queue.new
    workers = 4.times.map do
      Thread.new do
        gate.pop
        transport.request(uri, Net::HTTP::Get.new(uri)).body
      end
    end
    4.times { gate << true }

    expect(workers.map(&:value)).to eq(["ok"] * 4)
    expect(state).to include(peak: 2, completed: 4)
    expect(transport.connection_count).to eq(2)
  ensure
    transport&.close
    server&.close
    acceptor&.join(1)
    acceptor&.kill if acceptor&.alive?
    handlers&.each { |thread| thread.kill if thread.alive? }
    handlers&.each(&:join)
  end

  it "parses real chunked HTTP exec frames without losing delivered boundaries" do
    server = ScriptedHTTPServer.new do |socket, _|
      socket.write(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" \
        "Connection: close\r\n\r\n"
      )
      ["\x01out".b, "\x02err".b, "\x03\x00".b].each do |frame|
        socket.write("#{frame.bytesize.to_s(16)}\r\n#{frame}\r\n")
        socket.flush
      end
      socket.write("0\r\n\r\n")
    end
    client = Sprites::Client.new(
      "token",
      base_url: "http://127.0.0.1:#{server.port}",
      max_http_connections: 1
    )

    result = client.exec_file_http("demo/name", "cat", input: "hello")
    server.join

    expect(result.to_h).to eq(stdout: "out", stderr: "err", exit_code: 0)
    expect(server.request_line).to start_with("POST /v1/sprites/demo%2Fname/exec?")
    expect(server.body).to eq("hello")
  ensure
    client&.close
    server&.close
  end

  it "returns a real NDJSON stream after headers and releases it after incremental consumption" do
    release = Queue.new
    server = ScriptedHTTPServer.new do |socket, _|
      socket.write(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" \
        "Content-Type: application/x-ndjson\r\nConnection: close\r\n\r\n"
      )
      first = "{\"type\":\"info\"}\n"
      socket.write("#{first.bytesize.to_s(16)}\r\n#{first}\r\n")
      socket.flush
      release.pop
      last = "{\"type\":\"complete\"}\n"
      socket.write("#{last.bytesize.to_s(16)}\r\n#{last}\r\n0\r\n\r\n")
    end
    client = Sprites::Client.new(
      "token",
      base_url: "http://127.0.0.1:#{server.port}"
    )

    stream = client.create_checkpoint("demo")
    expect(client.open_connection_count).to eq(1)
    expect(stream.next_message.type).to eq("info")
    release << true
    expect(stream.next_message.type).to eq("complete")
    expect(stream.next_message).to be_nil
    stream.close

    expect(client.open_connection_count).to eq(0)
  ensure
    release << true if release
    stream&.close
    client&.close
    server&.close
  end

  it "drops inherited keep-alive descriptors in a forked Puma worker without touching the parent pool" do
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    release = Queue.new
    server = ScriptedHTTPServer.new do |socket, _|
      socket.write(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n" \
        "Connection: keep-alive\r\n\r\nok"
      )
      socket.flush
      release.pop
    end
    base_url = "http://127.0.0.1:#{server.port}"
    transport = Sprites::HTTPTransport.new(base_url:, max_connections: 1)
    uri = URI("#{base_url}/v1/sprites")
    expect(transport.request(uri, Net::HTTP::Get.new(uri)).body).to eq("ok")
    expect(transport.connection_count).to eq(1)
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      writer.write(transport.connection_count.to_s)
      writer.close
      transport.close
      exit! 0
    end
    writer.close
    child_count = reader.read
    Process.wait(pid)
    pid = nil

    expect(child_count).to eq("0")
    expect(transport.connection_count).to eq(1)
  ensure
    reader&.close
    writer&.close
    Process.wait(pid) if pid
    transport&.close
    release << true if release
    server&.close
  end
end
