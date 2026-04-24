# frozen_string_literal: true

# Example: Get Checkpoint
# Endpoint: GET /v1/sprites/{name}/checkpoints/{checkpoint_id}
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")
checkpoint_id = ENV.fetch("CHECKPOINT_ID", "v1")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

checkpoint = sprite.get_checkpoint(checkpoint_id)

puts JSON.pretty_generate({
  id: checkpoint.id,
  create_time: checkpoint.create_time&.iso8601,
  comment: checkpoint.comment,
  is_auto: checkpoint.is_auto,
  history: checkpoint.history
})
