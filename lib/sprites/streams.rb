# frozen_string_literal: true

# 流式响应读取器
#
# Checkpoint、Restore、Service 操作返回 NDJSON（每行一个 JSON）流。
# 这些类提供逐条读取和批量处理的接口，支持 Enumerable。

require "json"
require "stringio"

module Sprites
  class CheckpointStream
    def initialize(body)
      @body = body.is_a?(String) ? StringIO.new(body) : body
      @done = false
    end

    def next_message
      return nil if @done

      loop do
        line = @body.gets
        unless line
          @done = true
          return nil
        end

        line = line.strip
        next if line.empty?

        return StreamMessage.from_hash(JSON.parse(line))
      end
    rescue JSON::ParserError => e
      raise Error, "failed to parse message: #{e.message}"
    end

    def close
      @body&.close rescue nil
    end

    def process_all(&block)
      loop do
        msg = next_message
        break unless msg

        yield msg
      end
    ensure
      close
    end

    include Enumerable

    def each(&block)
      process_all(&block)
    end
  end

  class RestoreStream
    def initialize(body)
      @body = body.is_a?(String) ? StringIO.new(body) : body
      @done = false
    end

    def next_message
      return nil if @done

      loop do
        line = @body.gets
        unless line
          @done = true
          return nil
        end

        line = line.strip
        next if line.empty?

        return StreamMessage.from_hash(JSON.parse(line))
      end
    rescue JSON::ParserError => e
      raise Error, "failed to parse message: #{e.message}"
    end

    def close
      @body&.close rescue nil
    end

    def process_all(&block)
      loop do
        msg = next_message
        break unless msg

        yield msg
      end
    ensure
      close
    end

    include Enumerable

    def each(&block)
      process_all(&block)
    end
  end

  class ServiceStream
    def initialize(body)
      @body = body.is_a?(String) ? StringIO.new(body) : body
      @done = false
    end

    def next_event
      return nil if @done

      loop do
        line = @body.gets
        unless line
          @done = true
          return nil
        end

        line = line.strip
        next if line.empty?

        return ServiceLogEvent.from_hash(JSON.parse(line))
      end
    rescue JSON::ParserError => e
      raise Error, "failed to parse service log event: #{e.message}"
    end

    def close
      @body&.close rescue nil
    end

    def process_all(&block)
      loop do
        event = next_event
        break unless event

        yield event
      end
    ensure
      close
    end

    include Enumerable

    def each(&block)
      process_all(&block)
    end
  end
end
