# frozen_string_literal: true

# Example: Concurrent Running Limit Test
# Creates 30 sprites and runs commands on all of them simultaneously
# to trigger the concurrent running limit (typically 20).
require "sprites"

token = ENV.fetch("SPRITE_TOKEN")
client = Sprites::Client.new(token)

TOTAL = 30
names = TOTAL.times.map { |i| "limit-test-#{i}" }

# Step 1: Check current org limits
puts "=== Checking org limits ==="
result = client.list_all_sprites_result
org = result.org
if org
  puts "Org: #{org.name}"
  puts "Running: #{org.running}/#{org.running_limit}"
  puts "Warm: #{org.warm}/#{org.warm_limit}"
  puts "Cold: #{org.cold}"
else
  puts "Org info not available (total sprites: #{result.sprites.size})"
end
puts ""

# Step 2: Create sprites
puts "=== Creating #{TOTAL} sprites ==="
created = []
names.each_with_index do |name, i|
  client.create_sprite(name)
  created << name
  print "\r  #{i + 1}/#{TOTAL} created"
rescue Sprites::APIError => e
  puts "\n  #{i + 1}/#{TOTAL} create FAILED: #{e.error_code} - #{e.message}"
  break
end
puts ""

# Step 3: Launch commands on all sprites concurrently (sleep 30s to keep them running)
puts "\n=== Launching commands on #{created.size} sprites concurrently ==="
threads = []
results = Array.new(created.size)

created.each_with_index do |name, i|
  threads << Thread.new(i, name) do |idx, sprite_name|
    sprite = client.sprite(sprite_name)
    cmd = sprite.command("sleep", "30")
    cmd.start
    results[idx] = { name: sprite_name, status: :running }
    puts "  #{idx + 1}. #{sprite_name}: running"
  rescue Sprites::APIError => e
    results[idx] = { name: sprite_name, status: :api_error, error: e }
    puts "  #{idx + 1}. #{sprite_name}: API ERROR"
    puts "       error_code: #{e.error_code}"
    puts "       message: #{e.message}"
    puts "       status: #{e.status_code}"
    puts "       rate_limit?: #{e.rate_limit_error?}"
    puts "       creation_rate_limited?: #{e.creation_rate_limited?}"
    puts "       concurrent_limit?: #{e.concurrent_limit_exceeded?}"
    puts "       retry_after: #{e.get_retry_after_seconds}s"
  rescue Sprites::Error => e
    results[idx] = { name: sprite_name, status: :error, error: e }
    puts "  #{idx + 1}. #{sprite_name}: ERROR - #{e.message}"
  end
end

threads.each(&:join)

# Step 4: Summary
running = results.count { |r| r && r[:status] == :running }
api_errors = results.select { |r| r && r[:status] == :api_error }
other_errors = results.select { |r| r && r[:status] == :error }

puts "\n=== Summary ==="
puts "Running: #{running}/#{created.size}"
puts "API errors: #{api_errors.size}"
puts "Other errors: #{other_errors.size}"

if api_errors.any?
  e = api_errors.first[:error]
  puts "\nFirst API error (sprite ##{results.index(api_errors.first) + 1}):"
  puts "  error_code: #{e.error_code}"
  puts "  message: #{e.message}"
end

# Step 5: Cleanup
puts "\nCleaning up #{created.size} sprites..."
created.each { |name| client.delete_sprite(name) rescue nil }
puts "Done."
