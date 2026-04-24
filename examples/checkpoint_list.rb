# frozen_string_literal: true

# Example: List Checkpoints
# Endpoint: GET /v1/sprites/{name}/checkpoints
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

checkpoints = sprite.list_checkpoints

data = checkpoints.map do |cp|
  { id: cp.id, create_time: cp.create_time&.iso8601, comment: cp.comment }
end

puts JSON.pretty_generate(data)
