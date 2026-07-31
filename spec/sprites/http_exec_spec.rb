# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::HTTPExec do
  class FakeHTTPExecResponse
    attr_reader :code

    def initialize(code: "200", chunks: [], headers: {})
      @code = code
      @chunks = chunks
      @headers = headers
    end

    def [](name) = @headers[name]
    def read_body(&block) = @chunks.each(&block)
  end

  class FakeHTTPExecConnection
    attr_accessor :read_timeout, :open_timeout, :write_timeout, :max_retries
    attr_reader :last_request

    def initialize(response)
      @response = response
      @read_timeout = @open_timeout = @write_timeout = 30
    end

    def request(request)
      @last_request = request
      yield @response
      @response
    end
  end

  def client_for(response)
    connection = FakeHTTPExecConnection.new(response)
    client = Sprites::Client.new(
      "token",
      base_url: "https://example.test",
      http_client: connection
    )
    [client, connection]
  end

  it "executes with official repeated query fields and preserves output frame boundaries" do
    response = FakeHTTPExecResponse.new(
      chunks: ["\x01out".b, "\x02err".b, "\x03\x00".b]
    )
    client, connection = client_for(response)

    result = client.sprite("demo/name").exec_file_http(
      "cat",
      ["a b"],
      input: "hello",
      environment: { "MODE" => "test" },
      working_dir: "/app",
      timeout: 2
    )

    expect(result.to_h).to eq(stdout: "out", stderr: "err", exit_code: 0)
    expect(connection.last_request.body).to eq("hello")
    params = URI.decode_www_form(connection.last_request.uri.query)
    expect(params).to eq([
      ["cmd", "cat"], ["cmd", "a b"], ["path", "cat"],
      ["dir", "/app"], ["env", "MODE=test"], ["stdin", "true"]
    ])
    expect(connection.last_request.uri.path).to eq("/v1/sprites/demo%2Fname/exec")
    expect([connection.read_timeout, connection.open_timeout, connection.write_timeout])
      .to eq([30, 30, 30])
  ensure
    client&.close
  end

  it "raises ExecError with captured output for a non-zero exit" do
    response = FakeHTTPExecResponse.new(
      chunks: ["\x01out".b, "\x02failed".b, "\x03\x02".b]
    )
    client, = client_for(response)

    expect { client.exec_file_http("demo", "false") }
      .to raise_error(Sprites::ExecError) { |error|
        expect(error.exit_code).to eq(2)
        expect(error.stdout).to eq("out")
        expect(error.stderr).to eq("failed")
      }
  ensure
    client&.close
  end

  it "fails closed on ambiguous frames, missing exit, and buffer overflow" do
    invalid, = client_for(FakeHTTPExecResponse.new(chunks: ["\x7fdata".b]))
    missing, = client_for(FakeHTTPExecResponse.new(chunks: ["\x01out".b]))
    oversized, = client_for(FakeHTTPExecResponse.new(chunks: ["\x01large".b]))

    expect { invalid.exec_file_http("demo", "cat") }
      .to raise_error(Sprites::Error, /unsupported HTTP exec frame type 0x7f/)
    expect { missing.exec_file_http("demo", "cat") }
      .to raise_error(Sprites::Error, /did not include an exit frame/)
    expect { oversized.exec_file_http("demo", "cat", max_buffer: 2) }
      .to raise_error(Sprites::Error, /stdout max_buffer exceeded/)
  ensure
    invalid&.close
    missing&.close
    oversized&.close
  end

  it "uses structured API errors and validates local options before I/O" do
    response = FakeHTTPExecResponse.new(
      code: "429",
      chunks: [JSON.generate(error: "limited", message: "wait")],
      headers: { "Retry-After" => "3" }
    )
    client, = client_for(response)

    expect { client.exec_file_http("demo", "cat") }
      .to raise_error(Sprites::APIError) { |error|
        expect(error.status_code).to eq(429)
        expect(error.get_retry_after_seconds).to eq(3)
      }
    expect { client.exec_file_http("demo", "") }.to raise_error(ArgumentError, /file/)
    expect { client.exec_file_http("demo", "cat", timeout: -1) }
      .to raise_error(ArgumentError, /timeout/)
  ensure
    client&.close
  end
end
