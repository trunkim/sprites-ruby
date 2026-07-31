# frozen_string_literal: true

require "json"
require "stringio"

module Sprites
  # 单消费者 NDJSON stream 的公共实现。
  #
  # HTTP body 可以是真实增量 IO，也可以是测试/兼容路径中的 String。空行与单条
  # malformed JSON 对齐官方 JS SDK 直接跳过；需要 terminal contract 的操作由
  # CheckpointStream/RestoreStream#drain! 额外校验 complete。
  class NDJSONStream
    include Enumerable

    def initialize(body, &mapper)
      @body = body.is_a?(String) ? StringIO.new(body) : body
      @mapper = mapper || ->(data) { data }
      @done = false
      @closed = false
    end

    def next_item
      return if @done

      loop do
        line = @body.gets
        unless line
          @done = true
          close
          return
        end

        line = line.strip
        next if line.empty?

        begin
          return @mapper.call(JSON.parse(line))
        rescue JSON::ParserError
          next
        end
      end
    rescue Sprites::Error
      close
      raise
    rescue StandardError => e
      close
      raise Error, "stream read failed: #{e.class}: #{e.message}"
    end

    def process_all
      return enum_for(:process_all) unless block_given?

      begin
        while (item = next_item)
          yield item
        end
        nil
      ensure
        close
      end
    end

    def each(&block)
      return enum_for(:each) unless block

      process_all(&block)
    end

    def close
      return if @closed

      @closed = true
      @done = true
      @body&.close
      nil
    rescue IOError, SystemCallError
      nil
    end

    def closed? = @closed
  end

  class CheckpointStream < NDJSONStream
    def initialize(body)
      super(body) { |data| StreamMessage.from_hash(data) }
    end

    alias next_message next_item

    # 消费全部消息并校验终态：遇到 error 立即失败；必须以 complete 结束。
    def drain!
      saw_complete = false
      process_all do |message|
        case message.type.to_s
        when "error"
          detail = message.error.to_s
          detail = message.data.to_s if detail.empty?
          raise Error, detail.empty? ? "checkpoint stream error" : detail
        when "complete"
          saw_complete = true
        end
      end
      raise Error, "checkpoint stream ended without complete" unless saw_complete
    end
  end

  class RestoreStream < CheckpointStream
    def drain!
      saw_complete = false
      process_all do |message|
        case message.type.to_s
        when "error"
          detail = message.error.to_s
          detail = message.data.to_s if detail.empty?
          raise Error, detail.empty? ? "restore stream error" : detail
        when "complete"
          saw_complete = true
        end
      end
      raise Error, "restore stream ended without complete" unless saw_complete
    end
  end

  class ServiceStream < NDJSONStream
    def initialize(body)
      super(body) { |data| ServiceLogEvent.from_hash(data) }
    end

    alias next_event next_item
  end

  class SpriteStateStream < NDJSONStream
    def initialize(body)
      super(body) { |data| SpriteStateEvent.from_hash(data) }
    end

    alias next_event next_item
  end

  class SessionKillStream < NDJSONStream
    def initialize(body)
      super(body) { |data| SessionKillEvent.from_hash(data) }
    end

    alias next_event next_item
  end
end
