# frozen_string_literal: true

require "logger"

module Sprites
  # SDK 调试日志控制
  #
  # 可通过环境变量 SPRITES_SDK_DEBUG=1 或代码 Sprites.debug = true 开启。
  # 开启后，SDK 内部操作（WebSocket 连接、control pool 管理等）会输出到 stderr。

  @debug = ENV.fetch("SPRITES_SDK_DEBUG", nil)&.then { |v| v != "" && v != "0" && v != "false" } || false
  @logger = Logger.new($stderr, level: Logger::DEBUG, progname: "sprites")

  class << self
    # SDK 使用的 Logger 实例，可替换为自定义 logger
    attr_accessor :logger

    # @return [Boolean] 是否开启了调试模式
    def debug?
      @debug
    end

    # 开启或关闭调试日志
    # @param enabled [Boolean]
    def debug=(enabled)
      @debug = enabled
    end

    # 输出一条调试日志（仅在 debug 模式下生效）
    # @param msg [String] 日志消息
    # @param kwargs [Hash] 附加的键值对，会拼接在消息后面
    def dbg(msg, **kwargs)
      return unless @debug

      extra = kwargs.map { |k, v| "#{k}=#{v}" }.join(" ")
      @logger.debug(extra.empty? ? msg : "#{msg} #{extra}")
    end
  end
end
