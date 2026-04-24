# frozen_string_literal: true

# Example: List Services
# Endpoint: GET /v1/sprites/{name}/services
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

services = sprite.list_services

data = services.map do |s|
  { name: s.name, cmd: s.cmd, status: s.state&.status }
end

puts JSON.pretty_generate(data)
