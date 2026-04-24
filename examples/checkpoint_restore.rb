# frozen_string_literal: true

# Example: Restore Checkpoint
# Endpoint: POST /v1/sprites/{name}/checkpoints/{checkpoint_id}/restore
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")
checkpoint_id = ENV.fetch("CHECKPOINT_ID", "v1")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

stream = sprite.restore_checkpoint(checkpoint_id)
stream.process_all do |msg|
  puts JSON.generate({ type: msg.type, data: msg.data, error: msg.error })
end
