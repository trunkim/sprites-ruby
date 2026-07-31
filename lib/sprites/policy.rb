# frozen_string_literal: true

# 策略管理：network / privileges / resources
#
# 控制 sprite 的出站网络、权限与资源策略。
# 真实 API contract（2026-07 canary）：
#   resources  → { "memory": { "limit_mb": N, "autoscale": bool } }；DELETE 回默认
#   privileges → { "profile": "minimal|standard|privileged", "devices": [], "noNewPrivileges": bool }

require "json"

module Sprites
  module Policy
    def get_network_policy(sprite_name)
      resp = http_get(Routes.policy(sprite_name, "network"))
      data = parse_response!(resp)
      NetworkPolicy.from_hash(data)
    end

    def update_network_policy(sprite_name, policy)
      resp = http_post(Routes.policy(sprite_name, "network"), policy.to_h)

      case resp.code.to_i
      when 204 then nil
      when 400
        api_err = APIError.parse(resp, resp.body)
        raise api_err if api_err

        raise Error, "invalid policy: #{resp.body}"
      else
        parse_response!(resp)
      end
    end

    def get_privileges_policy(sprite_name)
      resp = http_get(Routes.policy(sprite_name, "privileges"))
      data = parse_response!(resp)
      PrivilegesPolicy.from_hash(data)
    end

    def update_privileges_policy(sprite_name, policy)
      body = policy.respond_to?(:to_h) ? policy.to_h : policy
      resp = http_post(Routes.policy(sprite_name, "privileges"), body)

      case resp.code.to_i
      when 204 then nil
      when 400
        api_err = APIError.parse(resp, resp.body)
        raise api_err if api_err

        raise Error, "invalid privileges policy: #{resp.body}"
      else
        parse_response!(resp)
      end
    end

    def delete_privileges_policy(sprite_name)
      resp = http_delete(Routes.policy(sprite_name, "privileges"))

      case resp.code.to_i
      when 200, 204 then nil
      else
        parse_response!(resp)
      end
    end

    def get_resources_policy(sprite_name)
      resp = http_get(Routes.policy(sprite_name, "resources"))
      data = parse_response!(resp)
      ResourcesPolicy.from_hash(data)
    end

    def update_resources_policy(sprite_name, policy)
      body = policy.respond_to?(:to_h) ? policy.to_h : policy
      resp = http_post(Routes.policy(sprite_name, "resources"), body)

      case resp.code.to_i
      when 204 then nil
      when 400
        api_err = APIError.parse(resp, resp.body)
        raise api_err if api_err

        raise Error, "invalid resources policy: #{resp.body}"
      else
        parse_response!(resp)
      end
    end

    def delete_resources_policy(sprite_name)
      resp = http_delete(Routes.policy(sprite_name, "resources"))

      case resp.code.to_i
      when 200, 204 then nil
      else
        parse_response!(resp)
      end
    end
  end

  class Sprite
    def get_network_policy
      client.get_network_policy(name)
    end

    def update_network_policy(policy)
      client.update_network_policy(name, policy)
    end

    def get_privileges_policy
      client.get_privileges_policy(name)
    end

    def update_privileges_policy(policy)
      client.update_privileges_policy(name, policy)
    end

    def delete_privileges_policy
      client.delete_privileges_policy(name)
    end

    def get_resources_policy
      client.get_resources_policy(name)
    end

    def update_resources_policy(policy)
      client.update_resources_policy(name, policy)
    end

    def delete_resources_policy
      client.delete_resources_policy(name)
    end
  end
end
