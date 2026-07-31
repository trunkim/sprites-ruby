# frozen_string_literal: true

# 服务管理（Service CRUD + 生命周期控制）
#
# 服务是 sprite 内的持久化后台进程（如 web server、数据库）。
# 创建、启动、停止操作返回流式响应（ServiceStream），可实时读取日志。

require "json"

module Sprites
  module Services
    def list_services(sprite_name)
      resp = http_get(Routes.services(sprite_name))
      data = parse_response!(resp)

      services = data.is_a?(Array) ? data : data.fetch("services", [])
      services.map { |service| ServiceWithState.from_hash(service) }
    end

    def get_service(sprite_name, service_name)
      resp = http_get(Routes.service(sprite_name, service_name))

      data = parse_response!(resp)
      ServiceWithState.from_hash(data)
    end

    def create_service(sprite_name, service_name, request, duration: nil)
      params = duration ? { duration: duration } : {}
      resp = http_put_stream(Routes.service(sprite_name, service_name), request.to_h, params: params)
      ServiceStream.new(parse_stream_response!(resp))
    end

    def delete_service(sprite_name, service_name)
      resp = http_delete(Routes.service(sprite_name, service_name))

      parse_response!(resp, expected: 204)
    end

    def start_service(sprite_name, service_name, duration: nil)
      params = duration ? { duration: duration } : {}
      resp = http_post_stream(
        Routes.service_action(sprite_name, service_name, "start"),
        nil,
        params: params
      )
      ServiceStream.new(parse_stream_response!(resp))
    end

    def stop_service(sprite_name, service_name, timeout: nil)
      params = timeout ? { timeout: timeout } : {}
      resp = http_post_stream(
        Routes.service_action(sprite_name, service_name, "stop"),
        nil,
        params: params
      )
      ServiceStream.new(parse_stream_response!(resp))
    end

    def restart_service(sprite_name, service_name, duration: nil)
      params = duration ? { duration: duration } : {}
      resp = http_post_stream(
        Routes.service_action(sprite_name, service_name, "restart"),
        nil,
        params: params
      )
      ServiceStream.new(parse_stream_response!(resp))
    end

    def service_logs(sprite_name, service_name, lines: nil, duration: nil)
      params = {}
      params[:lines] = Integer(lines) unless lines.nil?
      params[:duration] = duration if duration
      resp = http_get_stream(
        Routes.service_action(sprite_name, service_name, "logs"),
        params: params,
        headers: { "Accept" => "application/x-ndjson" }
      )
      ServiceStream.new(parse_stream_response!(resp))
    end

    def signal_service(sprite_name, service_name, signal)
      body = { name: service_name, signal: signal }
      resp = http_post("#{Routes.services(sprite_name)}/signal", body)

      parse_response!(resp, expected: 204)
    end
  end

  class Sprite
    def list_services
      client.list_services(name)
    end

    def get_service(service_name)
      client.get_service(name, service_name)
    end

    def create_service(service_name, request, duration: nil)
      client.create_service(name, service_name, request, duration: duration)
    end

    def delete_service(service_name)
      client.delete_service(name, service_name)
    end

    def start_service(service_name, duration: nil)
      client.start_service(name, service_name, duration: duration)
    end

    def stop_service(service_name, timeout: nil)
      client.stop_service(name, service_name, timeout: timeout)
    end

    def restart_service(service_name, duration: nil)
      client.restart_service(name, service_name, duration: duration)
    end

    def service_logs(service_name, lines: nil, duration: nil)
      client.service_logs(name, service_name, lines: lines, duration: duration)
    end

    def signal_service(service_name, signal)
      client.signal_service(name, service_name, signal)
    end
  end
end
