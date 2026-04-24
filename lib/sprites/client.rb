# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Sprites
  class Client
    include Management
    include Sessions
    include Checkpoints
    include Services
    include Policy
    include Proxy

    attr_reader :base_url, :token

    def initialize(token, base_url: "https://api.sprites.dev", http_client: nil,
                   control_init_timeout: 2, disable_control: false)
      @token = token
      @base_url = base_url.chomp("/")
      @http_timeout = 30
      @control_init_timeout = control_init_timeout
      @disable_control = disable_control

      @sprite_version = nil
      @version_mutex = Mutex.new

      @pools_mutex = Mutex.new
      @pools = {}
    end

    def sprite(name)
      s = Sprite.new(name: name, client: self)
      s.ensure_control_support
      s
    end

    def sprite_with_org(name, org)
      s = Sprite.new(name: name, client: self, org: org)
      s.ensure_control_support
      s
    end

    def sprite_version
      @version_mutex.synchronize { @sprite_version || "" }
    end

    def supports_path_attach?
      VersionDetection.supports_path_attach?(sprite_version)
    end

    def disable_control?
      @disable_control
    end

    def fetch_version(sprite_name)
      uri = URI("#{@base_url}/v1/sprites/#{sprite_name}/exec")
      req = Net::HTTP::Head.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      resp = perform_request(uri, req)
      capture_version(resp)
    end

    def get_or_create_pool(sprite_name)
      @pools_mutex.synchronize do
        @pools[sprite_name] ||= ControlPool.new(self, sprite_name)
      end
    end

    def signal_session(sprite_name, session_id, signal)
      uri = URI("#{@base_url}/v1/sprites/#{sprite_name}/exec/#{session_id}/kill?signal=#{signal}&timeout=0s")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@token}"

      resp = perform_request(uri, req)
      return if resp.code.to_i == 410 # Gone - session already exited
      return if resp.code.to_i == 200

      raise Error, "signal failed (status #{resp.code}): #{resp.body&.strip}"
    end

    def close
      @pools_mutex.synchronize do
        @pools.each_value(&:close)
        @pools.clear
      end
    end

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

    def capture_version(resp)
      version = resp["Sprite-Version"]
      if version && !version.empty?
        @version_mutex.synchronize { @sprite_version = version }
      end
    end

    def perform_request(uri, req)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @http_timeout
      http.read_timeout = @http_timeout
      resp = http.request(req)
      capture_version(resp)
      resp
    end

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
