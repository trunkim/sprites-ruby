# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::Policy do
  let(:client) { Sprites::Client.new("token", base_url: "https://example.test") }
  let(:sprite) { client.sprite("demo/name") }
  let(:base) { "https://example.test/v1/sprites/demo%2Fname/policy" }

  after { client.close }

  it "round-trips network policy with encoded Sprite names" do
    stub_request(:get, "#{base}/network").to_return(
      status: 200,
      body: JSON.generate(rules: [{ domain: "example.com", action: "allow", include: ["subdomains"] }])
    )
    stub_request(:post, "#{base}/network").to_return(status: 204)

    policy = sprite.get_network_policy
    expect(policy.rules.first.to_h).to eq(
      domain: "example.com", action: "allow", include: ["subdomains"]
    )
    expect { sprite.update_network_policy(policy) }.not_to raise_error
    expect(a_request(:post, "#{base}/network").with { |wire|
      JSON.parse(wire.body) == {
        "rules" => [{ "domain" => "example.com", "action" => "allow", "include" => ["subdomains"] }]
      }
    }).to have_been_made.once
  end

  it "maps privileges and resources camel/snake case and accepts any successful 2xx" do
    stub_request(:get, "#{base}/privileges").to_return(
      status: 200,
      body: JSON.generate(profile: "standard", devices: ["null"], noNewPrivileges: true)
    )
    stub_request(:post, "#{base}/privileges").to_return(status: 202)
    stub_request(:delete, "#{base}/privileges").to_return(status: 204)
    stub_request(:get, "#{base}/resources").to_return(
      status: 200,
      body: JSON.generate(memory: { limit_mb: 512, autoscale: true })
    )
    stub_request(:post, "#{base}/resources").to_return(status: 200)
    stub_request(:delete, "#{base}/resources").to_return(status: 204)

    privileges = sprite.get_privileges_policy
    expect(privileges.no_new_privileges).to be true
    sprite.update_privileges_policy(
      Sprites::PrivilegesPolicy.new(profile: "minimal", no_new_privileges: false)
    )
    sprite.delete_privileges_policy
    resources = sprite.get_resources_policy
    expect(resources.to_h).to eq(memory: { limit_mb: 512, autoscale: true })
    sprite.update_resources_policy(Sprites::ResourcesPolicy.new(limit_mb: 1024, autoscale: false))
    sprite.delete_resources_policy

    expect(a_request(:post, "#{base}/privileges").with { |wire|
      JSON.parse(wire.body) == { "profile" => "minimal", "noNewPrivileges" => false }
    }).to have_been_made.once
    expect(a_request(:post, "#{base}/resources").with { |wire|
      JSON.parse(wire.body) == { "memory" => { "limit_mb" => 1024, "autoscale" => false } }
    }).to have_been_made.once
  end

  it "raises structured API errors for every policy kind" do
    stub_request(:post, "#{base}/network").to_return(
      status: 400,
      body: JSON.generate(error: "invalid_policy", message: "bad rule")
    )
    policy = Sprites::NetworkPolicy.new(rules: [])

    expect { sprite.update_network_policy(policy) }
      .to raise_error(Sprites::APIError) { |error|
        expect(error.status_code).to eq(400)
        expect(error.error_code).to eq("invalid_policy")
      }
  end
end
