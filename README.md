# Sprite SDK for Ruby

The Sprite SDK provides an idiomatic Ruby API for working with sprites. It mirrors the Go SDK's `exec.Cmd`-like API to execute commands on remote Sprites as if they were local.

## Installation

Add to your Gemfile:

```ruby
gem "sprites"
```

Or install directly:

```bash
gem install sprites
```

**Requires Ruby >= 4.0** (tested with Ruby 4.0.6)

## Quick Start

```ruby
require "sprites"

# Create a client with authentication
client = Sprites::Client.new("your-auth-token")

# Get a sprite handle
sprite = client.sprite("my-sprite")

# Run a command
cmd = sprite.command("echo", "hello", "world")
output, err = cmd.output

puts "Output: #{output}"
```

## Usage

### Client Setup

```ruby
# Create a client with default settings
client = Sprites::Client.new("your-auth-token")

# Or with custom base URL
client = Sprites::Client.new("your-auth-token",
  base_url: "http://localhost:8080")

# Get a sprite handle
sprite = client.sprite("my-sprite")
```

`Client` 是连接生命周期边界。应用关闭 agent runtime、轮换 credential 或丢弃
client 时必须调用 `client.close`；它会关闭 HTTP pool、active command、stream、watcher、
proxy 与 control connection。

### Basic Command Execution

```ruby
# Create a command
cmd = sprite.command("ls", "-la", "/tmp")

# Run and wait for completion
err = cmd.run

# Or get the output
output, err = cmd.output

# Or get combined stdout and stderr
combined, err = cmd.combined_output
```

### Setting Environment and Working Directory

```ruby
cmd = sprite.command("env")
cmd.env = ["FOO=bar", "BAZ=qux"]
cmd.dir = "/tmp"

output, err = cmd.output
```

### Working with I/O

```ruby
cmd = sprite.command("grep", "pattern")

# Set stdin from a reader
cmd.stdin = StringIO.new("line 1\nline 2 with pattern\nline 3")

# Capture stdout and stderr separately
stdout = StringIO.new
stderr = StringIO.new
cmd.stdout = stdout
cmd.stderr = stderr

cmd.run
```

### Using Pipes

```ruby
cmd = sprite.command("cat")

# Get stdin pipe
stdin = cmd.stdin_pipe

# Get stdout pipe
stdout = cmd.stdout_pipe

# Start the command
cmd.start

# Write to stdin in a thread
Thread.new do
  10.times { |i| stdin.puts "Line #{i}" }
  stdin.close
end

# Read from stdout
stdout.each_line { |line| puts "Got: #{line}" }

# Wait for command to finish
cmd.wait
```

### TTY Support

```ruby
cmd = sprite.command("bash")
cmd.set_tty(true)

# Optionally set initial terminal size
cmd.set_tty_size(24, 80)

cmd.start

# Resize the terminal while running
cmd.resize(30, 100)

cmd.wait
```

### Error Handling

```ruby
cmd = sprite.command("false")
err = cmd.run

if err.is_a?(Sprites::ExitError)
  puts "Command exited with code: #{err.exit_code}"
else
  puts "Other error: #{err}"
end
```

### Sprite Management

```ruby
# Create a sprite
sprite = client.create_sprite("my-sprite",
  config: Sprites::SpriteConfig.new(ram_mb: 512, cpus: 2))

# Get sprite info
sprite = client.get_sprite("my-sprite")
puts sprite.status

# List sprites
result = client.list_sprites
result[:sprites].each { |s| puts s.name }

# Delete a sprite
client.delete_sprite("my-sprite")

# Upgrade a sprite
client.upgrade_sprite("my-sprite")
```

### Sessions

```ruby
# List active sessions
sessions = sprite.list_sessions
sessions.each do |s|
  puts "#{s.id}: #{s.command} (active: #{s.active?})"
end

# Attach to an existing session
cmd = sprite.attach_session("session-id")
cmd.run

# Create a detachable TTY session, then start it explicitly
session = sprite.create_session("bash", "-l")
session.start

# Kill a session and consume progress events
sprite.kill_session("session-id", timeout: "5s").each do |event|
  puts "#{event.type}: #{event.message}"
end
```

### HTTP Exec and Watchers

```ruby
# Non-TTY fallback for environments where WebSocket is unavailable.
# Prefer WebSocket Cmd for large output; see docs/official-js-compatibility.md.
result = sprite.exec_file_http(
  "cat",
  ["/etc/hostname"],
  input: "",
  timeout: 30
)

sprite.watch_ports.each { |event| puts event.inspect }

sprite.filesystem_at("/app").watch(["src", "test"], recursive: true).each do |event|
  puts "#{event.event}: #{event.path}"
end
```

并发、Fiber scheduler 与 Puma 部署边界见
[`docs/concurrency.md`](docs/concurrency.md)，官方 JS SDK 对照基线见
[`docs/official-js-compatibility.md`](docs/official-js-compatibility.md)。

### Checkpoints

```ruby
# Create a checkpoint
stream = sprite.create_checkpoint(comment: "before changes")
stream.each { |msg| puts "#{msg.type}: #{msg.data}" }

# List checkpoints
checkpoints = sprite.list_checkpoints
checkpoints.each { |cp| puts "#{cp.id}: #{cp.comment}" }

# Restore a checkpoint
stream = sprite.restore_checkpoint("checkpoint-id")
stream.each { |msg| puts "#{msg.type}: #{msg.data}" }
```

### Services

```ruby
# Create a service
req = Sprites::ServiceRequest.new(
  cmd: "nginx",
  args: ["-g", "daemon off;"],
  env: { "RAILS_ENV" => "development" },
  dir: "/workspace/app",
  http_port: 3000
)
stream = sprite.create_service("web", req)
stream.each { |event| puts "#{event.type}: #{event.data}" }

# List services
services = sprite.list_services
services.each { |s| puts "#{s.name}: #{s.state&.status}" }

# Start/stop services
sprite.start_service("web")
sprite.stop_service("web")
```

### Port Forwarding

```ruby
# Simple port forwarding
session = sprite.proxy_port(3000, 3000)
# Now localhost:3000 connects to the sprite's port 3000

# Clean up
session.close

# Multiple ports
sessions = sprite.proxy_ports([
  Sprites::PortMapping.new(local_port: 3000, remote_port: 3000),
  Sprites::PortMapping.new(local_port: 8080, remote_port: 80)
])
```

### Network Policy

```ruby
# Get current policy
policy = sprite.get_network_policy

# Update policy
policy = Sprites::NetworkPolicy.new(rules: [
  Sprites::NetworkPolicyRule.new(domain: "*.example.com", action: "allow"),
  Sprites::NetworkPolicyRule.new(domain: "evil.com", action: "deny")
])
sprite.update_network_policy(policy)
```

### Filesystem Operations

```ruby
# REST-based filesystem
fs = sprite.filesystem

# Read a file
data = fs.read_file("/etc/hostname")

# Write a file
fs.write_file("/tmp/hello.txt", "Hello, World!", mode: 0o644)

# List directory
entries = fs.read_dir("/tmp")
entries.each { |e| puts "#{e.name} (#{e.dir? ? 'dir' : 'file'})" }

# Other operations
fs.mkdir("/tmp/mydir")
fs.rename("/tmp/old", "/tmp/new")
fs.copy("/tmp/src", "/tmp/dst")
fs.remove("/tmp/file")
fs.chmod("/tmp/script.sh", 0o755)

# Control-channel filesystem (faster, requires control connection)
result = sprite.fs_read_control("/etc/hostname")
puts result.data

sprite.fs_write_control("/tmp/hello.txt", "Hello!")
```

### Debug Mode

```ruby
# Enable debug logging
Sprites.debug = true

# Or via environment variable
# SPRITES_SDK_DEBUG=1
```

### Token Creation

```ruby
# Create a sprite token from a Fly.io macaroon
token = Sprites::Client.create_token(
  "FlyV1...",          # Fly.io auth token
  "personal"           # Organization slug
)
```

## Testing

```bash
bundle exec rspec
```

## License

See the main project LICENSE file.
