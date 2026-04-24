# frozen_string_literal: true

# Example: List Sprites
# Endpoint: GET /v1/sprites
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")

client = Sprites::Client.new(token)

result = client.list_sprites
sprites = result[:sprites].map do |s|
  { name: s.name, status: s.status }
end

puts JSON.pretty_generate(sprites)
