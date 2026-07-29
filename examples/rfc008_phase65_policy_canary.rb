# frozen_string_literal: true

# Disposable Sprite canary for RFC-008 Phase 6.5 policy contract.
#
# Usage:
#   set -a && source .env && set +a
#   ruby examples/rfc008_phase65_policy_canary.rb
#
# Requires SPRITE_TOKEN. Never prints the token.

require "securerandom"
require_relative "../lib/sprites"

token = ENV["SPRITE_TOKEN"].to_s
token = ENV["SPRITES_TOKEN"].to_s if token.empty?
abort "missing SPRITE_TOKEN" if token.empty?

name = "rfc008-p65-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}"
client = Sprites::Client.new(token)
puts "client=#{Sprites::VERSION} sprite=#{name}"

begin
  client.create_sprite(name, wait_for_capacity: true)
  puts "create=ok"

  net = Sprites::NetworkPolicy.new(
    rules: [ Sprites::NetworkPolicyRule.new(domain: "*", action: "deny") ]
  )
  client.update_network_policy(name, net)
  got_net = client.get_network_policy(name)
  abort "network mismatch" unless got_net.rules.size == 1 && got_net.rules.first.domain == "*"
  puts "network=ok"

  priv = Sprites::PrivilegesPolicy.new(profile: "standard", devices: [])
  client.update_privileges_policy(name, priv)
  got_priv = client.get_privileges_policy(name)
  abort "privileges mismatch" unless got_priv.profile == "standard"
  puts "privileges=ok profile=#{got_priv.profile}"

  res = Sprites::ResourcesPolicy.new(limit_mb: 512, autoscale: false)
  client.update_resources_policy(name, res)
  got_res = client.get_resources_policy(name)
  abort "resources mismatch" unless got_res.limit_mb == 512 && got_res.autoscale == false
  puts "resources=ok limit_mb=#{got_res.limit_mb}"

  client.delete_resources_policy(name)
  after = client.get_resources_policy(name)
  abort "resources delete failed" unless after.limit_mb.nil?
  puts "resources_delete=ok"

  client.delete_privileges_policy(name)
  after_p = client.get_privileges_policy(name)
  abort "privileges delete failed" unless after_p.profile.to_s.empty?
  puts "privileges_delete=ok"

  puts "phase65_policy_canary=pass"
ensure
  begin
    client.destroy_sprite(name)
    puts "destroy=ok"
  rescue => e
    puts "destroy_err=#{e.class}: #{e.message}"
  end
end
