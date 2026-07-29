# frozen_string_literal: true

# Disposable Sprite contract canary for RFC-008 Phase 1.
#
# Usage:
#   set -a && source .env && set +a
#   ruby examples/rfc008_phase1_canary.rb
#
# Requires SPRITE_TOKEN (or SPRITES_TOKEN). Never prints the token.

require "securerandom"
require_relative "../lib/sprites"

token = ENV["SPRITE_TOKEN"].to_s
token = ENV["SPRITES_TOKEN"].to_s if token.empty?
abort "missing SPRITE_TOKEN" if token.empty?

name = "rfc008-canary-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}"
client = Sprites::Client.new(token)
puts "client=#{Sprites::VERSION} sprite=#{name}"

begin
  sprite = client.create_sprite(name, wait_for_capacity: true)
  puts "create=ok status=#{sprite.status}"

  got = client.get_sprite(name)
  puts "get=ok name=#{got.name}"

  handle = client.sprite(name)
  puts "handle_io=zero supports_control_before=#{handle.supports_control?}"

  cmd = handle.command("printf", "canary-ok\n")
  cmd.set_tty(false)
  cmd.set_max_run_after_disconnect(5)
  out, err = cmd.output
  puts "exec=ok out=#{out.inspect} err=#{err.inspect} mode=#{cmd.connection_mode}"

  comment = "rfc008-canary-#{SecureRandom.hex(4)}"
  cp = client.create_checkpoint!(name, comment: comment)
  puts "checkpoint=ok id=#{cp.id} health=#{cp.health.inspect} healthy=#{cp.healthy?} comment_match=#{cp.comment == comment}"

  sessions = client.list_sessions(name)
  puts "sessions=#{sessions.size}"

  list = client.list_sprites
  unless list[:sprites].size <= 50
    raise "list max_results contract broken: got #{list[:sprites].size}"
  end
  puts "list=ok count=#{list[:sprites].size} has_more=#{list[:has_more]}"
rescue => e
  warn "CANARY_FAIL class=#{e.class} msg=#{e.message[0, 300]}"
  exit 2
ensure
  begin
    client.delete_sprite(name) if name
    puts "delete=ok"
  rescue => e
    warn "delete=fail class=#{e.class} msg=#{e.message[0, 160]}"
  end
  client.close
  puts "close=ok"
end
