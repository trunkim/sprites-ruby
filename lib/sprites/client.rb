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
    include Policy       # get/update network policy
    include Proxy        # port forwarding, socket proxy

    # @return [String] API 基础 URL
    attr_reader :base_url
    # @return [String] 认证 token
    attr_reader :token

    # @param token [String] Sprite API 认证 token
    # @param base_url [String] API 基础 URL（默认 https://api.sprites.dev）
    # @param control_init_timeout [Integer] 控制连接初始化超时（秒）
    # @param disable_control [Boolean] 禁用控制连接（强制使用直接 WebSocket）
    def initialize(token, base_url: "https://api.sprites.dev", http_client: nil,
                   control_init_timeout: 2, disable_control: false)
      @token = token
      @base_url = base_url.chomp("/")
      @http_timeout = 30
      @control_init_timeout = control_init_timeout
      @disable_control = disable_control

      # 从 Sprite-Version 响应头捕获的服务端版本
      @sprite_version = nil
      @version_mutex = Mutex.new

      # 每个 sprite 一个控制连接池
      @pools_mutex = Mutex.new
      @pools = {}
    end

    # 获取 sprite 句柄（不会在服务端创建资源）
    # @param name [String] sprite 名称
    # @return [Sprite]
    def sprite(name)
      s = Sprite.new(name: name, client: self)
      s.ensure_control_support
      s
    end

    # 获取带组织信息的 sprite 句柄
    def sprite_with_org(name, org)
      s = Sprite.new(name: name, client: self, org: org)
      s.ensure_control_support
      s
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

      resp = perform_request(uri, req)
      capture_version(resp)
    end

    # 获取或创建指定 sprite 的控制连接池
    # @return [ControlPool]
    def get_or_create_pool(sprite_name)
      @pools_mutex.synchronize do
        @pools[sprite_name] ||= ControlPool.new(self, sprite_name)
      end
    end

    # 通过 HTTP POST 向 session 发送信号（WebSocket 信号的回退方案）
    def signal_session(sprite_name, session_id, signal)
      uri = URI("#{@base_url}/v1/sprites/#{sprite_name}/exec/#{session_id}/kill?signal=#{signal}&timeout=0s")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      resp = perform_request(uri, req)
      return if resp.code.to_i == 410  # Gone — session 已退出
      return if resp.code.to_i == 200

      raise Error, "signal failed (status #{resp.code}): #{resp.body&.strip}"
    end

    # 关闭客户端，释放所有控制连接池
    def close
      @pools_mutex.synchronize do
        @pools.each_value(&:close)
        @pools.clear
      end
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
    def perform_request(uri, req)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @http_timeout
      http.read_timeout = @http_timeout
      resp = http.request(req)
      capture_version(resp)
      resp
    end

    # ── HTTP 便捷方法 ──

    def http_get(path, params: {})
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      perform_request(uri, req)
    end

    def http_post(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      perform_request(uri, req)
    end

    def http_put(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      perform_request(uri, req)
    end

    def http_delete(path)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Delete.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      perform_request(uri, req)
    end

    # 用于流式响应的 POST（checkpoint/restore 等长时间操作）
    def http_post_stream(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @http_timeout
      http.read_timeout = 300
      http.keep_alive_timeout = 300

      http.request(req)
    end

    # 用于流式响应的 PUT（service create 等）
    def http_put_stream(path, body)
      uri = URI("#{@base_url}#{path}")

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body) if body

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @http_timeout
      http.read_timeout = 300
      http.keep_alive_timeout = 300

      http.request(req)
    end

    # 解析 HTTP 响应：成功时返回 JSON，失败时抛出 APIError
    def parse_response!(resp, expected: 200)
      body = resp.body

      unless resp.code.to_i == expected
        api_err = APIError.parse(resp, body)
        raise api_err if api_err

        raise Error, "API returned status #{resp.code}: #{body}"
      end

      JSON.parse(body)
    end
  end
end
