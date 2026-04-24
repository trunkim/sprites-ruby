# frozen_string_literal: true

# 服务管理（Service CRUD + 生命周期控制）
#
# 服务是 sprite 内的持久化后台进程（如 web server、数据库）。
# 创建、启动、停止操作返回流式响应（ServiceStream），可实时读取日志。

require "json"

module Sprites
  module Services
    def list_services(sprite_name)
      resp = http_get("/v1/sprites/#{sprite_name}/services")
      data = parse_response!(resp)

      data.map { |s| ServiceWithState.from_hash(s) }
    end

    def get_service(sprite_name, service_name)
      resp = http_get("/v1/sprites/#{sprite_name}/services/#{service_name}")

      if resp.code.to_i == 404
        raise Error, "service not found: #{service_name}"
      end

      data = parse_response!(resp)
      ServiceWithState.from_hash(data)
    end

    def create_service(sprite_name, service_name, request, duration: nil)
      path = "/v1/sprites/#{sprite_name}/services/#{service_name}"
      path += "?duration=#{duration}" if duration

      resp = http_put_stream(path, request.to_h)

      if resp.code.to_i == 409
        body = resp.body.read rescue ""
        raise Error, "service conflict: #{body}"
      end

      unless resp.code.to_i == 200
        body = resp.body.read rescue ""
        raise Error, "API returned status #{resp.code}: #{body}"
      end

      ServiceStream.new(resp.body)
    end

    def delete_service(sprite_name, service_name)
      resp = http_delete("/v1/sprites/#{sprite_name}/services/#{service_name}")

      case resp.code.to_i
      when 204 then nil
      when 404 then raise Error, "service not found: #{service_name}"
      when 409 then raise Error, "service conflict"
      else parse_response!(resp)
      end
    end

    def start_service(sprite_name, service_name, duration: nil)
      path = "/v1/sprites/#{sprite_name}/services/#{service_name}/start"
      path += "?duration=#{duration}" if duration

      resp = http_post_stream(path, nil)

      if resp.code.to_i == 404
        body = resp.body.read rescue ""
        raise Error, "service not found: #{body}"
      end

      unless resp.code.to_i == 200
        body = resp.body.read rescue ""
        raise Error, "API returned status #{resp.code}: #{body}"
      end

      ServiceStream.new(resp.body)
    end

    def stop_service(sprite_name, service_name, timeout: nil)
      path = "/v1/sprites/#{sprite_name}/services/#{service_name}/stop"
      path += "?timeout=#{timeout}" if timeout

      resp = http_post_stream(path, nil)

      case resp.code.to_i
      when 200
        ServiceStream.new(resp.body)
      when 404
        body = resp.body.read rescue ""
        raise Error, "service not found: #{body}"
      when 409
        body = resp.body.read rescue ""
        raise Error, "service not running: #{body}"
      else
        body = resp.body.read rescue ""
        raise Error, "API returned status #{resp.code}: #{body}"
      end
    end

    def signal_service(sprite_name, service_name, signal)
      body = { name: service_name, signal: signal }
      resp = http_post("/v1/sprites/#{sprite_name}/services/signal", body)

      case resp.code.to_i
      when 204 then nil
      when 404 then raise Error, "service not found"
      when 409 then raise Error, "service not running"
      when 400 then raise Error, "invalid signal"
      else parse_response!(resp)
      end
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

    def signal_service(service_name, signal)
      client.signal_service(name, service_name, signal)
    end
  end
end
