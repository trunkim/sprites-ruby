# frozen_string_literal: true

require "json"

module Sprites
  # 单消费者 WebSocket JSON stream。读取发生在调用方 thread/Fiber；不创建
  # background thread，也不做无界事件排队。Client#close 会关闭尚未结束的 watcher。
  class WebSocketJSONStream
    include Enumerable

    def initialize(connection, initial_message: nil, on_release: nil, &mapper)
      @connection = connection
      @initial_message = initial_message
      @on_release = on_release
      @mapper = mapper || ->(data) { data }
      @mutex = Mutex.new
      @closed = false
      @released = false
    end

    def connect!
      @connection.connect!
      @connection.write_text(JSON.generate(@initial_message)) unless @initial_message.nil?
      self
    rescue StandardError
      close
      raise
    end

    def next_event
      return if closed?

      loop do
        message = @connection.read_message
        unless message
          close
          return
        end

        type, payload = message
        if type == :close
          close
          return
        end
        next unless type == :text

        begin
          return @mapper.call(JSON.parse(payload))
        rescue JSON::ParserError
          next
        end
      end
    rescue StandardError
      close
      raise
    end

    alias next_item next_event

    def each
      return enum_for(:each) unless block_given?

      while (event = next_event)
        yield event
      end
    ensure
      close
    end

    def close
      release = @mutex.synchronize do
        return if @closed

        @closed = true
        next if @released

        @released = true
        @on_release
      end
      begin
        @connection.close
      ensure
        release&.call
      end
      nil
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def connection_open?
      !closed? && !@connection.closed?
    end
  end

  class PortWatcher < WebSocketJSONStream
    def initialize(connection, **options)
      super(connection, **options) do |data|
        if data["type"] == "port_list"
          PortList.from_hash(data)
        else
          PortNotificationMessage.from_hash(data)
        end
      end
    end
  end

  class FilesystemWatcher < WebSocketJSONStream
    def initialize(connection, paths:, working_dir:, recursive:, **options)
      super(
        connection,
        initial_message: {
          type: "subscribe",
          paths: Array(paths),
          recursive: recursive == true,
          workingDir: working_dir
        },
        **options
      ) { |data| FilesystemWatchEvent.from_hash(data) }
    end
  end

  module Watch
    def watch_ports(sprite_name)
      open_websocket_json_stream(PortWatcher, Routes.ports_watch(sprite_name))
    end

    def watch_filesystem(sprite_name, paths, working_dir: "/", recursive: false)
      normalized_paths = Array(paths).map(&:to_s)
      raise ArgumentError, "at least one path is required" if normalized_paths.empty?
      raise ArgumentError, "path must not be empty" if normalized_paths.any?(&:empty?)

      open_websocket_json_stream(
        FilesystemWatcher,
        Routes.filesystem_watch(sprite_name),
        paths: normalized_paths,
        working_dir: working_dir,
        recursive: recursive
      )
    end
  end

  class Sprite
    def watch_ports
      client.watch_ports(name)
    end
  end

  class SpriteFS
    def watch(paths, recursive: false)
      @sprite.client.watch_filesystem(
        @sprite.name,
        paths,
        working_dir: @working_dir,
        recursive:
      )
    end
  end
end
