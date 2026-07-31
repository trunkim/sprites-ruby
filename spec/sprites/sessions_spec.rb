# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Sessions do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }

  describe "#list_sessions" do
    it "returns session objects" do
      stub_request(:get, "http://localhost:8080/v1/sprites/demo/exec")
        .to_return(
          status: 200,
          body: JSON.generate({
            sessions: [
              { "id" => "s1", "command" => "bash", "is_active" => true, "tty" => true }
            ]
          }),
          headers: { "Content-Type" => "application/json" }
        )

      sessions = client.list_sessions("demo")
      expect(sessions.size).to eq(1)
      expect(sessions.first.id).to eq("s1")
      expect(sessions.first.tty).to be true
    end

    it "forwards bounded timeouts without Net::HTTP implicit retries" do
      response = Struct.new(:code, :body) do
        def [](_key) = nil
      end.new("200", JSON.generate({ sessions: [] }))
      http = instance_double(
        Net::HTTP,
        read_timeout: 30,
        open_timeout: 30,
        "read_timeout=": nil,
        "open_timeout=": nil,
        "max_retries=": nil
      )
      allow(http).to receive(:request).and_return(response)
      bounded = Sprites::Client.new(
        "test-token",
        base_url: "http://localhost:8080",
        http_client: http
      )

      expect(bounded.list_sessions("demo", timeout: 2)).to eq([])
      expect(http).to have_received(:read_timeout=).with(2).ordered
      expect(http).to have_received(:open_timeout=).with(2).ordered
      expect(http).to have_received(:read_timeout=).with(30).ordered
      expect(http).to have_received(:open_timeout=).with(30).ordered
      expect(http).to have_received(:max_retries=).with(0).once
    end
  end

  describe "#attach_session" do
    it "builds a Cmd with session id and tty off by default" do
      cmd = client.attach_session("demo", "42")
      expect(cmd).to be_a(Sprites::Cmd)
      expect(cmd.send(:instance_variable_get, :@session_id)).to eq("42")
      expect(cmd.send(:instance_variable_get, :@tty)).to be false
    end

    it "allows explicit tty opt-in" do
      cmd = client.attach_session("demo", "42", tty: true)
      expect(cmd.send(:instance_variable_get, :@tty)).to be true
    end
  end

  describe "#kill_session" do
    it "posts kill with signal and timeout and maps progress incrementally" do
      request = stub_request(
        :post,
        "http://localhost:8080/v1/sprites/demo/exec/42/kill?signal=TERM&timeout=5s"
      ).with { |wire| wire.headers["Content-Type"].nil? }
        .to_return(
          status: 200,
          body: "{\"type\":\"signal\",\"pid\":2}\n{\"type\":\"complete\",\"exit_code\":0}\n"
        )

      stream = client.kill_session("demo", "42", timeout: "5s")

      expect(stream.next_event.pid).to eq(2)
      expect(stream.next_event.exit_code).to eq(0)
      expect(request).to have_been_requested
    ensure
      stream&.close
    end

    it "raises typed APIError on failure" do
      stub_request(:post, "http://localhost:8080/v1/sprites/demo/exec/42/kill?signal=KILL")
        .to_return(
          status: 404,
          body: JSON.generate({ error: "not_found", message: "session gone" }),
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.kill_session("demo", "42", signal: "KILL") }.to raise_error(Sprites::APIError) { |err|
        expect(err.status_code).to eq(404)
      }
    end
  end
end
