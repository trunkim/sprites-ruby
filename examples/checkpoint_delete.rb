# frozen_string_literal: true

# Example: Delete Checkpoint
# Endpoint: DELETE /v1/sprites/{name}/checkpoints/{checkpoint_id}
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")
checkpoint_id = ENV.fetch("CHECKPOINT_ID", "v1")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

sprite.delete_checkpoint(checkpoint_id)

puts "Checkpoint '#{checkpoint_id}' deleted"
