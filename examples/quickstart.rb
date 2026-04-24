# frozen_string_literal: true

# Example: Quick Start
require "sprites"

# Setup client
client = Sprites::Client.new(ENV.fetch("SPRITE_TOKEN"))

# Create a sprite
client.create_sprite(ENV.fetch("SPRITE_NAME"))

# Run Python
sprite = client.sprite(ENV.fetch("SPRITE_NAME"))
output, = sprite.command("python", "-c", "print(2+2)").output
print output

# Clean up
client.destroy_sprite(ENV.fetch("SPRITE_NAME"))
