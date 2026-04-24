# frozen_string_literal: true

# Example: Create Checkpoint
# Endpoint: POST /v1/sprites/{name}/checkpoint
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

stream = sprite.create_checkpoint(comment: "my-checkpoint")
stream.process_all do |msg|
  puts JSON.generate({ type: msg.type, data: msg.data, error: msg.error })
end
