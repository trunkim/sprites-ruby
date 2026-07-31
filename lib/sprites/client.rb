# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Sprites
  # Sprites SDK 主客户端
  #
  # 所有 API 操作的入口。通过 token 认证，支持自定义 base URL。
  # 混入了各功能模块：Management、Sessions、Checkpoints、Services、Policy、Proxy。
  #
  # HTTP transport 属于本 Client 的 activity/maintenance scope：可注入 http_client，
  # 或使用内部 keep-alive Net::HTTP；Client#close 关闭 transport 与全部 control pool。
  #
  # @example 基本用法
  #   client = Sprites::Client.new("your-token")
  #   sprite = client.sprite("my-sprite")
  #   output, err = sprite.command("echo", "hello").output
  #
  # @example 自定义配置
  #   client = Sprites::Client.new("token",
  #     base_url: "http://localhost:8080",
  #     disable_control: true)
  class Client
    include Management   # create/get/list/delete/upgrade sprites
    include Sessions     # list/attach sessions
    include Checkpoints  # create/list/get/restore checkpoints
    include Services     # CRUD services, start/stop/signal
    include Policy       # get/update network/privileges/resources policy
    include Proxy        # port forwarding, socket proxy

    DEFAULT_MAX_CONTROL_CONNECTIONS = 8
    DEFAULT_CONTROL_DRAIN_THRESHOLD = 4
    DEFAULT_CONTROL_DRAIN_TARGET = 2

    # @return [String] API 基础 URL
    attr_reader :base_url
    # @return [String] 认证 token
    attr_reader :token
    # @return [Integer] 每个 sprite 的 control 连接池上限
    attr_reader :max_control_connections
    # @return [Integer] 触发空闲连接清理的阈值
    attr_reader :control_drain_threshold
    # @return [Integer] 清理后保留的空闲连接数
    attr_reader :control_drain_target

    # @param token [String] Sprite API 认证 token
    # @param base_url [String] API 基础 URL（默认 https://api.sprites.dev）
    # @param http_client [Net::HTTP, #request] 可选注入的 HTTP transport；须能 request(req)
    # @param control_init_timeout [Integer] 控制连接初始化超时（秒）
    # @param disable_control [Boolean] 禁用控制连接（强制使用直接 WebSocket）
    # @param max_control_connections [Integer] 每 sprite control 池上限（默认 8，不再使用固定 100）
    def initialize(token, base_url: "https://api.sprites.dev", http_client: nil,
                   control_init_timeout: 2, disable_control: false,
                   max_control_connections: DEFAULT_MAX_CONTROL_CONNECTIONS,
                   control_drain_threshold: DEFAULT_CONTROL_DRAIN_THRESHOLD,
                   control_drain_target: DEFAULT_CONTROL_DRAIN_TARGET)
      @token = token
      @base_url = base_url.chomp("/")
      @http_timeout = 30
      @control_init_timeout = control_init_timeout
      @disable_control = disable_control
      @max_control_connections = Integer(max_control_connections)
      @control_drain_threshold = Integer(control_drain_threshold)
      @control_drain_target = Integer(control_drain_target)
      raise ArgumentError, "max_control_connections must be >= 1" if @max_control_connections < 1
      raise ArgumentError, "control_drain_target must be >= 0" if @control_drain_target.negative?
      if @control_drain_threshold < @control_drain_target
        raise ArgumentError, "control_drain_threshold must be >= control_drain_target"
      end

      # 从 Sprite-Version 响应头捕获的服务端版本
      @sprite_version = nil
      @version_mutex = Mutex.new

      # 每个 sprite 一个控制连接池（仅属于本 Client scope）
      @pools_mutex = Mutex.new
      @pools = {}

      @http_mutex = Mutex.new
      @owns_http_client = http_client.nil?
      @http_client = http_client
      disable_implicit_http_retries!(@http_client)
      @closed = false
    end

    # 获取 sprite 句柄（零 I/O；不在服务端创建资源，也不探测 control）
    # @param name [String] sprite 名称
    # @return [Sprite]
    def sprite(name)
      Sprite.new(name: name, client: self)
    end

    # 获取带组织信息的 sprite 句柄（零 I/O）
    def sprite_with_org(name, org)
      Sprite.new(name: name, client: self, org: org)
    end

    # @return [String] 捕获到的服务端版本，未知时返回空字符串
    def sprite_version
      @version_mutex.synchronize { @sprite_version || "" }
    end

    # @return [Boolean] 服务端是否支持 path-based attach 端点
    def supports_path_attach?
      VersionDetection.supports_path_attach?(sprite_version)
    end

    # @return [Boolean] 是否禁用了控制连接
    def disable_control?
      @disable_control
    end

    # 发送 HEAD 请求以捕获 Sprite-Version 响应头
    def fetch_version(sprite_name)
      uri = URI("#{@base_url}/v1/sprites/#{sprite_name}/exec")
      req = Net::HTTP::Head.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      resp = request(uri, req)
      capture_version(resp)
    end

    # 获取或创建指定 sprite 的控制连接池
    # @return [ControlPool]
    def get_or_create_pool(sprite_name)
      @pools_mutex.synchronize do
        raise Error, "client is closed" if @closed

        @pools[sprite_name] ||= ControlPool.new(
          self,
          sprite_name,
          max_size: @max_control_connections,
          drain_threshold: @control_drain_threshold,
          drain_target: @control_drain_target
        )
      end
    end

    # 通过 HTTP POST 向 session 发送信号（WebSocket 信号的回退方案）
    def signal_session(sprite_name, session_id, signal)
      uri = URI("#{@base_url}/v1/sprites/#{sprite_name}/exec/#{session_id}/kill?signal=#{signal}&timeout=0s")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      resp = request(uri, req)
      return if resp.code.to_i == 410  # Gone — session 已退出
      return if resp.code.to_i == 200

      api_err = APIError.parse(resp, resp.body)
      raise api_err if api_err

      raise Error, "signal failed (status #{resp.code}): #{resp.body&.strip}"
    end

    # 关闭客户端：释放全部 control pool、HTTP transport 与后台线程
    def close
      pools = nil
      @pools_mutex.synchronize do
        return if @closed

        @closed = true
        pools = @pools.values
        @pools = {}
      end

      pools&.each(&:close)

      @http_mutex.synchronize do
        if @owns_http_client && @http_client
          @http_client.finish if @http_client.respond_to?(:started?) && @http_client.started?
        end
        @http_client = nil if @owns_http_client
      end
    end

    # 公开 HTTP 入口，供 filesystem 等模块复用同一 transport
    def request(uri, req, read_timeout: nil, open_timeout: nil)
      perform_request(uri, req, read_timeout: read_timeout, open_timeout: open_timeout)
    end

    # 使用 Fly.io macaroon token 创建 Sprite API token
    # @param fly_macaroon [String] Fly.io 认证 token（FlyV1 开头）
    # @param org_slug [String] 组织标识（如 "personal"）
    # @param invite_code [String, nil] 邀请码（可选）
    # @param api_url [String] API 地址
    # @return [String] 新创建的 Sprite API token
    def self.create_token(fly_macaroon, org_slug, invite_code: nil, api_url: "https://api.sprites.dev")
      uri = URI("#{api_url}/v1/organizations/#{org_slug}/tokens")

      body = { description: "Sprite SDK Token" }
      body[:invite_code] = invite_code if invite_code && !invite_code.empty?

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "FlyV1 #{fly_macaroon}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 30
      http.read_timeout = 30
      resp = http.request(req)

      unless [200, 201].include?(resp.code.to_i)
        api_err = APIError.parse(resp, resp.body)
        raise api_err if api_err

        raise Error, "API returned status #{resp.code}: #{resp.body}"
      end

      data = JSON.parse(resp.body)
      raise Error, "no token returned in response" if data["token"].nil? || data["token"].empty?

      data["token"]
    end

    private

    # 从响应头中捕获 Sprite-Version
    def capture_version(resp)
      version = resp["Sprite-Version"]
      if version && !version.empty?
        @version_mutex.synchronize { @sprite_version = version }
      end
    end

    # 执行 HTTP 请求并自动捕获版本头
    def perform_request(uri, req, read_timeout: nil, open_timeout: nil)
      @http_mutex.synchronize do
        raise Error, "client is closed" if @closed

        http = http_transport_for(uri)
        previous_read = nil
        previous_open = nil
        if read_timeout && http.respond_to?(:read_timeout=)
          previous_read = http.read_timeout
          http.read_timeout = read_timeout
        end
        if open_timeout && http.respond_to?(:open_timeout=)
          previous_open = http.open_timeout
          http.open_timeout = open_timeout
        end

        begin
          resp = http.request(req)
          capture_version(resp)
          resp
        ensure
          http.read_timeout = previous_read if previous_read && http.respond_to?(:read_timeout=)
          http.open_timeout = previous_open if previous_open && http.respond_to?(:open_timeout=)
        end
      end
    end

    def http_transport_for(uri)
      if @http_client
        configure_http!(@http_client, uri) if @owns_http_client
        return @http_client
      end

      @http_client = build_http(uri)
      @owns_http_client = true
      @http_client
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      configure_http!(http, uri)
      http.start
      http
    end

    def configure_http!(http, uri)
      return unless http.is_a?(Net::HTTP)

      http.use_ssl = uri.scheme == "https" if http.respond_to?(:use_ssl=)
      http.open_timeout = @http_timeout if http.respond_to?(:open_timeout=)
      http.read_timeout = @http_timeout if http.respond_to?(:read_timeout=)
      http.keep_alive_timeout = @http_timeout if http.respond_to?(:keep_alive_timeout=)
      disable_implicit_http_retries!(http)
    end

    # Net::HTTP 默认会隐式重试 idempotent request，使上层 deadline 与重试策略失真。
    # SDK 只做一次 wire attempt；是否重试由理解业务语义的调用方决定。
    def disable_implicit_http_retries!(http)
      http.max_retries = 0 if http&.respond_to?(:max_retries=)
    end

    # ── HTTP 便捷方法 ──

    def http_get(path, params: {}, read_timeout: nil, open_timeout: nil)
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      request(uri, req, read_timeout: read_timeout, open_timeout: open_timeout)
    end

    def http_post(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      request(uri, req)
    end

    def http_put(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      request(uri, req)
    end

    def http_delete(path)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Delete.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      request(uri, req)
    end

    # 用于流式响应的 POST（checkpoint/restore 等长时间操作）
    def http_post_stream(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      request(uri, req, read_timeout: 300)
    end

    # 用于流式响应的 PUT（service create 等）
    def http_put_stream(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      request(uri, req, read_timeout: 300)
    end

    # 解析 HTTP 响应：成功时返回 JSON，失败时抛出 APIError
    def parse_response!(resp, expected: 200)
      body = resp.body
      code = resp.code.to_i
      expected_codes = Array(expected)

      unless expected_codes.include?(code)
        api_err = APIError.parse(resp, body)
        raise api_err if api_err

        raise Error, "API returned status #{resp.code}: #{body}"
      end

      return nil if body.nil? || body.empty?

      JSON.parse(body)
    end
  end
end
