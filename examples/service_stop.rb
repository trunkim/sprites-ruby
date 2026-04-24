# frozen_string_literal: true

# Example: Stop Service
# Endpoint: POST /v1/sprites/{name}/services/{service_name}/stop
require "sprites"
require "json"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")
service_name = ENV.fetch("SERVICE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

stream = sprite.stop_service(service_name)
stream.process_all do |event|
  puts JSON.generate({ type: event.type, data: event.data, exit_code: event.exit_code })
end
