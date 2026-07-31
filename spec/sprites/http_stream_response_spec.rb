# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::HTTPStreamResponse do
  class FakeStreamingHTTP
    attr_reader :finish_count

    def initialize(response, on_finish: nil)
      @response = response
      @on_finish = on_finish
      @started = true
      @finish_count = 0
    end

    def request(_request)
      yield @response
    end

    def started? = @started

    def finish
      @finish_count += 1
      @started = false
      @on_finish&.call
    end
  end

  class FakeStreamingResponse
    attr_reader :code

    def initialize(code: "200", headers: {}, &reader)
      @code = code
      @headers = headers
      @reader = reader
    end

    def each_header(&block) = @headers.each(&block)
    def read_body(&block) = @reader.call(&block)
  end

  let(:uri) { URI("https://api.example.test/v1/sprites/demo/checkpoint") }
  let(:request) { Net::HTTP::Post.new(uri) }

  it "returns after response headers and exposes body chunks incrementally" do
    release = Queue.new
    response = FakeStreamingResponse.new(headers: { "content-type" => "application/x-ndjson" }) do |&emit|
      emit.call("{\"type\":\"info\"}\n")
      release.pop
      emit.call("{\"type\":\"complete\"}\n")
    end
    http = FakeStreamingHTTP.new(response)
    stream = described_class.new(
      uri:,
      request:,
      timeout: 30,
      connection_factory: ->(*) { http }
    ).start

    expect(stream.code).to eq("200")
    expect(stream.connection_open?).to be true
    expect(stream.body.gets).to eq("{\"type\":\"info\"}\n")
    release << true
    expect(stream.body.gets).to eq("{\"type\":\"complete\"}\n")
    expect(stream.body.gets).to be_nil
  ensure
    stream&.close
  end

  it "closes an in-flight producer and invokes release exactly once" do
    waiting = Queue.new
    released = Queue.new
    callbacks = 0
    response = FakeStreamingResponse.new do |_emit|
      waiting << true
      released.pop
    end
    http = FakeStreamingHTTP.new(response, on_finish: -> { released << true })
    stream = described_class.new(
      uri:,
      request:,
      timeout: 30,
      on_release: -> { callbacks += 1 },
      connection_factory: ->(*) { http }
    ).start
    waiting.pop

    stream.close

    expect(stream).to be_closed
    expect(stream.connection_open?).to be false
    expect(callbacks).to eq(1)
    expect(http.finish_count).to be >= 1
  end

  it "raises connection failures before publishing a response" do
    stream = described_class.new(
      uri:,
      request:,
      timeout: 30,
      connection_factory: ->(*) { raise SocketError, "offline" }
    )

    expect { stream.start }.to raise_error(SocketError, "offline")
    expect(stream).to be_closed
  end
end
