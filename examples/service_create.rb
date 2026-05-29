# frozen_string_literal: true

# Example: Create Service
# Endpoint: PUT /v1/sprites/{name}/services/{service_name}
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")
service_name = ENV.fetch("SERVICE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

stream = sprite.create_service(service_name, Sprites::ServiceRequest.new(
  cmd: "python",
  args: ["-m", "http.server", "8000"],
  env: ENV.fetch("SERVICE_ENV_JSON", "{}").then { |value| JSON.parse(value) },
  dir: ENV["SERVICE_DIR"],
  http_port: 8000
))

stream.process_all do |event|
  puts JSON.generate({ type: event.type, data: event.data, exit_code: event.exit_code })
end
