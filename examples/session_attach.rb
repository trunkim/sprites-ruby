# frozen_string_literal: true

# Example: Attach to Session
# Endpoint: WSS /v1/sprites/{name}/exec/{session_id}
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

# Find the session from exec example
sessions = sprite.list_sessions
target_session = sessions.find do |s|
  s.command.include?("time.sleep") || s.command.include?("python")
end

unless target_session
  puts "No running session found"
  exit 1
end

puts "Attaching to session #{target_session.id}..."

# Attach and read buffered output (includes data from before we connected)
cmd = sprite.attach_session(target_session.id)
stdout = cmd.stdout_pipe
cmd.start

# Read for 3 seconds then disconnect
reader = Thread.new do
  loop do
    data = stdout.readpartial(4096)
    print data
  end
rescue EOFError
  # stream ended
end

sleep 3
reader.kill
