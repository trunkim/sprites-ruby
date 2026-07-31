# frozen_string_literal: true

module Sprites
  # SDK 基础异常类
  class Error < StandardError; end

  # 命令以非零退出码结束时抛出
  #
  # @example
  #   begin
  #     sprite.command("false").run
  #   rescue Sprites::ExitError => e
  #     puts e.exit_code #=> 1
  #   end
  class ExitError < Error
    # @return [Integer] 进程退出码
    attr_reader :exit_code

    # @param code [Integer] 进程退出码
    def initialize(code)
      @exit_code = code
      super("exit status #{code}")
    end
  end

  # 收集式 exec 的非零退出错误；保留 stdout/stderr，便于调用方诊断。
  class ExecError < ExitError
    attr_reader :result

    def initialize(result)
      @result = result
      super(result.exit_code)
    end

    def stdout = result.stdout
    def stderr = result.stderr
  end

  # 在 Wait 之前未调用 Start 时抛出
  class NotStartedError < Error
    def initialize
      super("sprite: command not started")
    end
  end

  # 重复调用 Start 时抛出
  class AlreadyStartedError < Error
    def initialize
      super("sprite: already started")
    end
  end

  # API 返回的结构化错误（HTTP 4xx/5xx）
  #
  # 包含错误码、限流信息、重试时间等详细字段。
  # 通过 APIError.parse(response, body) 从 HTTP 响应中解析。
  #
  # @example 判断限流错误
  #   rescue Sprites::APIError => e
  #     if e.rate_limit_error?
  #       sleep e.get_retry_after_seconds
  #       retry
  #     end
  class APIError < Error
    # @return [String] 机器可读的错误码（如 "sprite_creation_rate_limited"）
    attr_accessor :error_code
    # @return [String] 人类可读的错误描述
    attr_accessor :message
    # @return [Integer] 限流阈值
    attr_accessor :limit
    # @return [Integer] 限流窗口（秒）
    attr_accessor :window_seconds
    # @return [Integer] 建议的重试等待秒数（来自 JSON body）
    attr_accessor :retry_after_seconds
    # @return [Integer] 当前并发数（用于并发限制错误）
    attr_accessor :current_count
    # @return [Boolean] 是否有可用的升级方案
    attr_accessor :upgrade_available
    # @return [String] 升级链接
    attr_accessor :upgrade_url
    # @return [Integer] HTTP 状态码
    attr_accessor :status_code
    # @return [Integer] Retry-After 响应头的值（秒）
    attr_accessor :retry_after_header
    # @return [Integer] X-RateLimit-Limit 响应头
    attr_accessor :rate_limit_limit
    # @return [Integer] X-RateLimit-Remaining 响应头
    attr_accessor :rate_limit_remaining
    # @return [Integer] X-RateLimit-Reset 响应头（Unix 时间戳）
    attr_accessor :rate_limit_reset

    # 创建速率限制错误码
    ERR_CODE_CREATION_RATE_LIMITED = "sprite_creation_rate_limited"
    # 并发数量限制错误码
    ERR_CODE_CONCURRENT_LIMIT_EXCEEDED = "concurrent_sprite_limit_exceeded"

    # @param attrs [Hash] 属性键值对
    def initialize(attrs = {})
      attrs.each { |k, v| public_send(:"#{k}=", v) if respond_to?(:"#{k}=") }
      super(to_s)
    end

    def to_s
      return @message if @message && !@message.empty?
      return @error_code if @error_code && !@error_code.empty?

      "API error (status #{@status_code})"
    end

    # @return [Boolean] 是否为 429 限流错误
    def rate_limit_error?
      @status_code == 429
    end

    # @return [Boolean] 是否为创建速率限制
    def creation_rate_limited?
      @error_code == ERR_CODE_CREATION_RATE_LIMITED
    end

    # @return [Boolean] 是否为并发数量超限
    def concurrent_limit_exceeded?
      @error_code == ERR_CODE_CONCURRENT_LIMIT_EXCEEDED
    end

    # 获取建议的重试等待秒数，优先使用 JSON body 中的值，回退到 Retry-After 头
    # @return [Integer]
    def get_retry_after_seconds
      return @retry_after_seconds if @retry_after_seconds && @retry_after_seconds > 0

      @retry_after_header || 0
    end

    # 从 HTTP 响应中解析 API 错误
    # @param response [Net::HTTPResponse] HTTP 响应对象
    # @param body [String] 响应体
    # @return [APIError, nil] 解析出的错误，或 nil（状态码 < 400 时）
    def self.parse(response, body)
      return nil if response.code.to_i < 400

      api_err = new(status_code: response.code.to_i)

      # 解析限流相关的响应头
      if (ra = response["Retry-After"])
        api_err.retry_after_header = ra.to_i
      end
      if (rl = response["X-RateLimit-Limit"])
        api_err.rate_limit_limit = rl.to_i
      end
      if (rr = response["X-RateLimit-Remaining"])
        api_err.rate_limit_remaining = rr.to_i
      end
      if (rs = response["X-RateLimit-Reset"])
        api_err.rate_limit_reset = rs.to_i
      end

      # 尝试解析 JSON body
      if body && !body.empty?
        begin
          data = JSON.parse(body)
          api_err.error_code = data["error"]
          api_err.message = data["message"]
          api_err.limit = data["limit"]
          api_err.window_seconds = data["window_seconds"]
          api_err.retry_after_seconds = data["retry_after_seconds"]
          api_err.current_count = data["current_count"]
          api_err.upgrade_available = data["upgrade_available"]
          api_err.upgrade_url = data["upgrade_url"]
        rescue JSON::ParserError
          api_err.message = body
        end
      end

      if (api_err.message.nil? || api_err.message.empty?) &&
         (api_err.error_code.nil? || api_err.error_code.empty?)
        api_err.message = "API error (status #{api_err.status_code})"
      end

      api_err
    end
  end

  # 判断一个异常是否为 APIError，是则返回该错误，否则返回 nil
  # @param err [Exception]
  # @return [APIError, nil]
  def self.api_error?(err)
    err.is_a?(APIError) ? err : nil
  end

  # 判断一个异常是否为限流错误（HTTP 429），是则返回该错误
  # @param err [Exception]
  # @return [APIError, nil]
  def self.rate_limit_error?(err)
    api_err = api_error?(err)
    api_err&.rate_limit_error? ? api_err : nil
  end
end
