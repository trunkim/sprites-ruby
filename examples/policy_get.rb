# frozen_string_literal: true

# Example: Get Network Policy
# Endpoint: GET /v1/sprites/{name}/policy/network
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

policy = sprite.get_network_policy

data = {
  rules: policy.rules.map { |r| { domain: r.domain, action: r.action, include: r.include } }
}

puts JSON.pretty_generate(data)
