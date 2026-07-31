# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Sprites management public surface" do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }
  let(:sprite_payload) do
    {
      id: "sprite-1",
      name: "demo/name",
      organization: "test-org",
      status: "running",
      config: { ram_mb: 4096, cpus: 4, region: "ord", storage_gb: 10 },
      environment: { "MODE" => "test" },
      created_at: "2026-07-20T10:00:00Z",
      updated_at: "2026-07-20T11:00:00Z",
      version: "1.2.3",
      environment_version: "4.5.6",
      labels: %w[sdk test],
      url_settings: { auth: "sprite", private_access: "admins" }
    }
  end

  after { client.close }

  it "creates with every official option and maps all returned metadata" do
    stub_request(:post, "http://localhost:8080/v1/sprites")
      .to_return(status: 201, body: JSON.generate(sprite_payload))

    sprite = client.create_sprite(
      "demo/name",
      config: Sprites::SpriteConfig.new(ram_mb: 4096, cpus: 4, region: "ord", storage_gb: 10),
      environment: { "MODE" => "test" },
      url_settings: Sprites::URLSettings.new(auth: "sprite", private_access: "admins"),
      labels: %w[sdk test],
      wait_for_capacity: true,
      runtime: "dev"
    )

    expect(a_request(:post, "http://localhost:8080/v1/sprites").with { |wire|
      JSON.parse(wire.body) == {
        "name" => "demo/name",
        "config" => { "ram_mb" => 4096, "cpus" => 4, "region" => "ord", "storage_gb" => 10 },
        "environment" => { "MODE" => "test" },
        "url_settings" => { "auth" => "sprite", "private_access" => "admins" },
        "labels" => %w[sdk test],
        "wait_for_capacity" => true,
        "runtime" => "dev"
      }
    }).to have_been_made.once
    expect(sprite.version).to eq("1.2.3")
    expect(sprite.environment_version).to eq("4.5.6")
    expect(sprite.url_settings.private_access).to eq("admins")
  end

  it "encodes names and preserves list counts, bulk_load, update, restart, and check" do
    stub_request(:get, "http://localhost:8080/v1/sprites/demo%2Fname")
      .to_return(status: 200, body: JSON.generate(sprite_payload))
    stub_request(
      :get,
      "http://localhost:8080/v1/sprites?bulk_load=true&continuation_token=a%2Fb&max_results=10&prefix=demo"
    ).to_return(
      status: 200,
      body: JSON.generate(
        sprites: [sprite_payload], has_more: false, running: 1, warm: 2, cold: 3,
        name: "test-org", running_limit: 10, warm_limit: 20
      )
    )
    stub_request(:put, "http://localhost:8080/v1/sprites/demo%2Fname")
      .to_return(status: 200, body: JSON.generate(sprite_payload))
    stub_request(:post, "http://localhost:8080/v1/sprites/demo%2Fname/restart")
      .to_return(
        status: 202,
        body: JSON.generate(sprite_name: "demo/name", machine_id: "machine-1", message: "queued")
      )
    stub_request(:get, "http://localhost:8080/v1/sprites/demo%2Fname/check")
      .to_return(
        status: 200,
        body: JSON.generate(
          sprite_name: "demo/name", sprite_id: "sprite-1", status: "ok",
          checked_at: "2026-07-20T12:00:00Z", elapsed: 0.25
        )
      )

    expect(client.get_sprite("demo/name").id).to eq("sprite-1")
    page = client.list_sprites(
      Sprites::ListOptions.new(
        prefix: "demo", max_results: 10, continuation_token: "a/b", bulk_load: true
      )
    )
    expect(page[:org].to_h).to include(running: 1, warm: 2, cold: 3, running_limit: 10, warm_limit: 20)
    expect(client.update_sprite("demo/name", labels: []).labels).to eq(%w[sdk test])
    expect(
      a_request(:put, "http://localhost:8080/v1/sprites/demo%2Fname")
        .with(body: JSON.generate(labels: []))
    ).to have_been_made.once
    expect(client.restart_sprite("demo/name").machine_id).to eq("machine-1")
    expect(client.check_sprite("demo/name").checked_at).to eq(Time.parse("2026-07-20T12:00:00Z"))
    expect { client.update_sprite("demo/name") }.to raise_error(ArgumentError, /required/)
  end

  it "streams Sprite state events with the official NDJSON accept header" do
    watch = stub_request(:get, "http://localhost:8080/v1/sprites?max_results=5&prefix=dev-")
      .with(headers: { "Accept" => "application/x-ndjson" })
      .to_return(
        status: 200,
        body: JSON.generate(
          name: "demo", status: "running", running_version: "1.2.3",
          last_running_at: "2026-07-20T10:00:00Z",
          org: { name: "test-org", running: 1, warm: 2, cold: 3 }
        ) + "\n"
      )

    stream = client.watch_sprites(prefix: "dev-", max_results: 5)
    event = stream.next_event

    expect(event.running_version).to eq("1.2.3")
    expect(event.organization.running).to eq(1)
    expect(watch).to have_been_requested
  ensure
    stream&.close
  end
end
