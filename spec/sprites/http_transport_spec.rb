# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::HTTPTransport do
  Response = Struct.new(:code, :body, :headers) do
    def [](name) = headers&.fetch(name, nil)
  end

  class FakeHTTPConnection
    attr_accessor :read_timeout, :open_timeout, :write_timeout
    attr_reader :finish_count

    def initialize(&request_handler)
      @request_handler = request_handler
      @read_timeout = 30
      @open_timeout = 30
      @write_timeout = 30
      @started = true
      @finish_count = 0
    end

    def request(request)
      response = @request_handler.call(request, self)
      yield response if block_given?
      response
    end

    def started? = @started

    def finish
      @finish_count += 1
      @started = false
    end
  end

  let(:base_url) { "https://api.example.test" }
  let(:uri) { URI("#{base_url}/v1/sprites") }
  let(:response) { Response.new("200", "{}", {}) }

  it "runs requests concurrently up to the configured connection cap" do
    state = { active: 0, peak: 0 }
    mutex = Mutex.new
    factory = lambda do |_base_uri, _timeout|
      FakeHTTPConnection.new do
        mutex.synchronize do
          state[:active] += 1
          state[:peak] = [state[:peak], state[:active]].max
        end
        sleep 0.03
        response
      ensure
        mutex.synchronize { state[:active] -= 1 }
      end
    end
    transport = described_class.new(base_url:, max_connections: 2, connection_factory: factory)
    gate = Queue.new

    threads = 3.times.map do
      Thread.new do
        gate.pop
        transport.request(uri, Net::HTTP::Get.new(uri))
      end
    end
    3.times { gate << true }
    threads.each(&:join)

    expect(state[:peak]).to eq(2)
    expect(transport.connection_count).to eq(2)
  ensure
    transport&.close
  end

  it "restores per-request timeouts before returning a connection to the pool" do
    observed = []
    connection = FakeHTTPConnection.new do |_request, http|
      observed << [http.read_timeout, http.open_timeout]
      response
    end
    transport = described_class.new(base_url:, connection_factory: ->(*) { connection })

    transport.request(uri, Net::HTTP::Get.new(uri), read_timeout: 2, open_timeout: 3)
    transport.request(uri, Net::HTTP::Get.new(uri))

    expect(observed).to eq([[2, 3], [30, 30]])
  ensure
    transport&.close
  end

  it "consumes streaming responses in the caller and preserves delivered chunks" do
    chunks = ["\x01out".b, "\x03\x00".b]
    streaming_response = Response.new("200", nil, {})
    streaming_response.define_singleton_method(:read_body) do |&block|
      chunks.each(&block)
    end
    connection = FakeHTTPConnection.new { streaming_response }
    transport = described_class.new(base_url:, connection_factory: ->(*) { connection })

    delivered = transport.request_stream(
      uri,
      Net::HTTP::Post.new(uri),
      read_timeout: 2,
      open_timeout: 3,
      write_timeout: 4
    ) { |response| response.read_body.to_a }

    expect(delivered).to eq(chunks)
    expect([connection.read_timeout, connection.open_timeout, connection.write_timeout])
      .to eq([30, 30, 30])
    expect(transport.connection_count).to eq(1)
  ensure
    transport&.close
  end

  it "discards a streaming connection when body processing fails" do
    connection = FakeHTTPConnection.new { response }
    transport = described_class.new(base_url:, connection_factory: ->(*) { connection })

    expect {
      transport.request_stream(uri, Net::HTTP::Get.new(uri)) { raise "bad frame" }
    }.to raise_error(RuntimeError, "bad frame")
    expect(transport.connection_count).to eq(0)
    expect(connection.finish_count).to eq(1)
  ensure
    transport&.close
  end

  it "discards a connection after a failed request instead of reusing poisoned state" do
    created = 0
    factory = lambda do |_base_uri, _timeout|
      created += 1
      if created == 1
        FakeHTTPConnection.new { raise EOFError, "truncated response" }
      else
        FakeHTTPConnection.new { response }
      end
    end
    transport = described_class.new(base_url:, connection_factory: factory)

    expect { transport.request(uri, Net::HTTP::Get.new(uri)) }.to raise_error(EOFError)
    expect(transport.connection_count).to eq(0)
    expect(transport.request(uri, Net::HTTP::Get.new(uri))).to equal(response)
    expect(created).to eq(2)
  ensure
    transport&.close
  end

  it "closes checked-out connections and fences new requests" do
    started = Queue.new
    released = Queue.new
    connection = FakeHTTPConnection.new do
      started << true
      released.pop
      response
    end
    connection.define_singleton_method(:finish) do
      super()
      released << true
    end
    transport = described_class.new(base_url:, connection_factory: ->(*) { connection })
    request_thread = Thread.new { transport.request(uri, Net::HTTP::Get.new(uri)) }
    started.pop

    transport.close
    request_thread.join

    expect(connection.finish_count).to eq(1)
    expect(transport.connection_count).to eq(0)
    expect { transport.request(uri, Net::HTTP::Get.new(uri)) }
      .to raise_error(Sprites::Error, "client is closed")
  end

  it "rejects cross-origin requests" do
    transport = described_class.new(base_url:, connection_factory: ->(*) { raise "must not connect" })
    other = URI("https://other.example.test/v1/sprites")

    expect { transport.request(other, Net::HTTP::Get.new(other)) }
      .to raise_error(ArgumentError, /origin/)
  ensure
    transport&.close
  end
end
