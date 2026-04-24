# frozen_string_literal: true

# Example: Create Sprite
# Endpoint: POST /v1/sprites
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)

client.create_sprite(sprite_name, labels: ["prod"])

puts "Sprite '#{sprite_name}' created"
