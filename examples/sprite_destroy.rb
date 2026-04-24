# frozen_string_literal: true

# Example: Destroy Sprite
# Endpoint: DELETE /v1/sprites/{name}
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)

client.destroy_sprite(sprite_name)

puts "Sprite '#{sprite_name}' destroyed"
