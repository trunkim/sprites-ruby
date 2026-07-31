# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Services do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }
  let(:service_path) { "http://localhost:8080/v1/sprites/demo%2Fname/services/web%20api" }

  after { client.close }

  it "covers list/get/create/start/stop/restart/logs/signal/delete with encoded resources" do
    stub_request(:get, "http://localhost:8080/v1/sprites/demo%2Fname/services")
      .to_return(
        status: 200,
        body: JSON.generate(
          services: [
            {
              name: "web api", cmd: "node", http_port: 3000,
              state: { name: "web api", status: "running", restart_count: 2 }
            }
          ]
        )
      )
    stub_request(:get, service_path)
      .to_return(status: 200, body: JSON.generate(name: "web api", cmd: "node"))
    stub_request(:put, "#{service_path}?duration=5s")
      .to_return(status: 200, body: "{\"type\":\"started\",\"timestamp\":1}\n")
    stub_request(:post, "#{service_path}/start?duration=5s")
      .to_return(status: 200, body: "{\"type\":\"started\",\"timestamp\":2}\n")
    stub_request(:post, "#{service_path}/stop?timeout=10s")
      .to_return(status: 200, body: "{\"type\":\"stopped\",\"exit_code\":0,\"timestamp\":3}\n")
    stub_request(:post, "#{service_path}/restart?duration=5s")
      .to_return(status: 200, body: "{\"type\":\"started\",\"timestamp\":4}\n")
    stub_request(:get, "#{service_path}/logs?duration=1s&lines=10")
      .with(headers: { "Accept" => "application/x-ndjson" })
      .to_return(status: 200, body: "{\"type\":\"stdout\",\"data\":\"log\",\"timestamp\":5}\n")
    stub_request(:post, "http://localhost:8080/v1/sprites/demo%2Fname/services/signal")
      .to_return(status: 204)
    stub_request(:delete, service_path).to_return(status: 204)

    service = client.list_services("demo/name").first
    expect(service.args).to eq([])
    expect(service.needs).to eq([])
    expect(service.state.restart_count).to eq(2)
    expect(client.get_service("demo/name", "web api").name).to eq("web api")

    config = Sprites::ServiceRequest.new(cmd: "node", env: { "MODE" => "test" }, http_port: 3000)
    expect(client.create_service("demo/name", "web api", config, duration: "5s").next_event.type).to eq("started")
    expect(a_request(:put, "#{service_path}?duration=5s").with { |wire|
      JSON.parse(wire.body) == { "cmd" => "node", "env" => { "MODE" => "test" }, "http_port" => 3000 }
    }).to have_been_made.once
    expect(client.start_service("demo/name", "web api", duration: "5s").next_event.type).to eq("started")
    expect(client.stop_service("demo/name", "web api", timeout: "10s").next_event.exit_code).to eq(0)
    expect(client.restart_service("demo/name", "web api", duration: "5s").next_event.type).to eq("started")
    expect(client.service_logs("demo/name", "web api", lines: 10, duration: "1s").next_event.data).to eq("log")
    expect(client.signal_service("demo/name", "web api", "TERM")).to be_nil
    expect(client.delete_service("demo/name", "web api")).to be_nil
  end

  it "returns structured API errors instead of losing streaming error bodies" do
    stub_request(:post, "#{service_path}/start")
      .to_return(
        status: 409,
        body: JSON.generate(error: "service_conflict", message: "already running")
      )

    expect { client.start_service("demo/name", "web api") }
      .to raise_error(Sprites::APIError) { |error|
        expect(error.status_code).to eq(409)
        expect(error.message).to eq("already running")
      }
  end
end
