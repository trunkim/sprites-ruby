# frozen_string_literal: true

# Sprites SDK for Ruby
#
# An idiomatic Ruby SDK for the Sprites API (https://api.sprites.dev).
# Provides command execution, filesystem access, port forwarding,
# checkpoints, services, and network policy management on remote Sprites.
#
# @example Basic usage
#   client = Sprites::Client.new("your-token")
#   sprite = client.sprite("my-sprite")
#   output, err = sprite.command("echo", "hello").output
#   puts output #=> "hello\n"
#
# @see Sprites::Client
# @see Sprites::Sprite
# @see Sprites::Cmd

require_relative "sprites/version"
require_relative "sprites/debug"
require_relative "sprites/errors"
require_relative "sprites/types"
require_relative "sprites/version_detection"
require_relative "sprites/ws_adapter"
require_relative "sprites/ws_cmd"
require_relative "sprites/control_pool"
require_relative "sprites/cmd"
require_relative "sprites/filesystem"
require_relative "sprites/filesystem_control"
require_relative "sprites/streams"
require_relative "sprites/sprite"
require_relative "sprites/management"
require_relative "sprites/sessions"
require_relative "sprites/checkpoints"
require_relative "sprites/services"
require_relative "sprites/policy"
require_relative "sprites/proxy"
require_relative "sprites/client"
