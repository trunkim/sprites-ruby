# frozen_string_literal: true

# 执行会话管理
#
# 提供列出活跃 session 和 attach 到已有 session 的功能。
# TTY 模式的命令会创建可 attach 的 session。

require "json"

module Sprites
  module Sessions
    def list_sessions(sprite_name)
      resp = http_get("/v1/sprites/#{sprite_name}/exec")
      data = parse_response!(resp)

      sessions_raw = data["sessions"] || []
      sessions_raw.map { |s| Session.from_hash(s) }
    end

    def attach_session(sprite_name, session_id, org: nil)
      sprite = Sprite.new(name: sprite_name, client: self, org: org)
      cmd = Cmd.new(sprite: sprite, name: "", args: [])
      cmd.send(:session_id=, session_id)
      cmd
    end
  end

  class Sprite
    def list_sessions
      client.list_sessions(name)
    end

    def attach_session(session_id)
      client.attach_session(name, session_id, org: org)
    end
  end
end
