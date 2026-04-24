# frozen_string_literal: true

require "json"

module Sprites
  module Policy
    def get_network_policy(sprite_name)
      resp = http_get("/v1/sprites/#{sprite_name}/policy/network")
      data = parse_response!(resp)
      NetworkPolicy.from_hash(data)
    end

    def update_network_policy(sprite_name, policy)
      resp = http_post("/v1/sprites/#{sprite_name}/policy/network", policy.to_h)

      case resp.code.to_i
      when 204 then nil
      when 400
        body = resp.body
        raise Error, "invalid policy: #{body}"
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
  end
end
