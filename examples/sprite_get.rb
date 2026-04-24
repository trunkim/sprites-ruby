# frozen_string_literal: true

# Example: Get Sprite
# Endpoint: GET /v1/sprites/{name}
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)

sprite = client.get_sprite(sprite_name)

puts JSON.pretty_generate({
  id: sprite.id,
  name: sprite.name,
  status: sprite.status,
  organization: sprite.organization_name
})
