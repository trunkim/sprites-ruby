# frozen_string_literal: true

# Example: Get Service
# Endpoint: GET /v1/sprites/{name}/services/{service_name}
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")
service_name = ENV.fetch("SERVICE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

service = sprite.get_service(service_name)

puts JSON.pretty_generate({
  name: service.name,
  cmd: service.cmd,
  args: service.args,
  http_port: service.http_port,
  state: service.state ? {
    status: service.state.status,
    pid: service.state.pid
  } : nil
})
