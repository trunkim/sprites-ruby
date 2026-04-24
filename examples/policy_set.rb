# frozen_string_literal: true

# Example: Set Network Policy
# Endpoint: POST /v1/sprites/{name}/policy/network
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

policy = Sprites::NetworkPolicy.new(rules: [
  Sprites::NetworkPolicyRule.new(domain: "api.github.com", action: "allow"),
  Sprites::NetworkPolicyRule.new(domain: "*.npmjs.org", action: "allow")
])

sprite.update_network_policy(policy)

puts "Network policy updated"
