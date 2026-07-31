# frozen_string_literal: true

require "uri"

module Sprites
  # Sprites HTTP/WebSocket 路由的唯一构造入口。
  #
  # 固定 path 与动态 resource identifier 在这里分离；sprite、session、
  # checkpoint、service、organization 名称都按 RFC 3986 path segment 编码，
  # 避免 `/`、`?`、`#` 等字符改变请求路由。
  module Routes
    module_function

    def sprites = "/v1/sprites"
    def sprite(name) = "#{sprites}/#{segment(name)}"

    def exec(sprite_name) = "#{sprite(sprite_name)}/exec"
    def session(sprite_name, session_id) = "#{exec(sprite_name)}/#{segment(session_id)}"
    def session_kill(sprite_name, session_id) = "#{session(sprite_name, session_id)}/kill"

    def checkpoint_create(sprite_name) = "#{sprite(sprite_name)}/checkpoint"
    def checkpoints(sprite_name) = "#{sprite(sprite_name)}/checkpoints"
    def checkpoint(sprite_name, checkpoint_id) = "#{checkpoints(sprite_name)}/#{segment(checkpoint_id)}"
    def checkpoint_restore(sprite_name, checkpoint_id) = "#{checkpoint(sprite_name, checkpoint_id)}/restore"

    def services(sprite_name) = "#{sprite(sprite_name)}/services"
    def service(sprite_name, service_name) = "#{services(sprite_name)}/#{segment(service_name)}"
    def service_action(sprite_name, service_name, action) = "#{service(sprite_name, service_name)}/#{action}"

    def policy(sprite_name, kind) = "#{sprite(sprite_name)}/policy/#{kind}"
    def filesystem(sprite_name) = "#{sprite(sprite_name)}/fs"
    def proxy(sprite_name) = "#{sprite(sprite_name)}/proxy"
    def control(sprite_name) = "#{sprite(sprite_name)}/control"
    def ports_watch(sprite_name) = "#{sprite(sprite_name)}/ports/watch"
    def filesystem_watch(sprite_name) = "#{filesystem(sprite_name)}/watch"

    def organization_tokens(org_slug) = "/v1/organizations/#{segment(org_slug)}/tokens"

    def uri(base_url, path, params: nil)
      result = URI("#{base_url.to_s.sub(%r{/+\z}, "")}#{path}")
      result.query = URI.encode_www_form(params) if params && !params.empty?
      result
    end

    def websocket_uri(base_url, path, params: nil)
      uri(base_url.to_s.sub(/\Ahttp/, "ws"), path, params: params)
    end

    def segment(value)
      URI.encode_uri_component(value.to_s)
    end
    private_class_method :segment
  end
end
