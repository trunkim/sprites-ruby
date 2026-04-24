# frozen_string_literal: true

# Example: Update Sprite
# Endpoint: PUT /v1/sprites/{name}
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)

client.update_sprite(sprite_name,
  url_settings: Sprites::URLSettings.new(auth: "public"),
  labels: ["prod"])

puts "Sprite updated"
