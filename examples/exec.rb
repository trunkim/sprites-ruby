# frozen_string_literal: true

# Example: Execute Command
# Endpoint: WSS /v1/sprites/{name}/exec
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
sprite_name = ENV.fetch("SPRITE_NAME")

client = Sprites::Client.new(token)
sprite = client.sprite(sprite_name)

# Start a command that runs for 30s (TTY sessions stay alive after disconnect)
cmd = sprite.command("python3", "-c",
  "import time; print('Server ready on port 8080', flush=True); time.sleep(30)")
cmd.set_tty(true) # TTY sessions are detachable

stdout = cmd.stdout_pipe
cmd.start

# Read for 5 seconds then disconnect (session keeps running)
reader = Thread.new do
  loop do
    data = stdout.readpartial(4096)
    print data
  end
rescue EOFError
  # stream ended
end

sleep 5
reader.kill
