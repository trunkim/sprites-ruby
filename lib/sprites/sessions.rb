# frozen_string_literal: true

# 执行会话管理
#
# 提供列出活跃 session、attach、以及 HTTP kill 的能力。
# TTY 必须由调用方显式 opt in；Rails 普通 Tool 应固定 tty=false。

require "json"

module Sprites
  module Sessions
    def list_sessions(sprite_name, timeout: nil)
      resp = http_get(
        Routes.exec(sprite_name),
        read_timeout: timeout,
        open_timeout: timeout
      )
      data = parse_response!(resp)

      sessions_raw = data["sessions"] || []
      sessions_raw.map { |s| Session.from_hash(s) }
    end

    # 构造可 attach 的 Cmd。不会自动 start；TTY 默认 false，调用方按需 set_tty(true)。
    def attach_session(sprite_name, session_id, org: nil, tty: false)
      raise ArgumentError, "session_id is required" if session_id.nil? || session_id.to_s.empty?

      sprite = Sprite.new(name: sprite_name, client: self, org: org)
      cmd = Cmd.new(sprite: sprite, name: "", args: [])
      cmd.send(:session_id=, session_id.to_s)
      cmd.set_tty(true) if tty
      cmd
    end

    # HTTP kill：发送信号并返回官方 NDJSON progress stream。
    def kill_session(sprite_name, session_id, signal: "TERM", timeout: nil)
      raise ArgumentError, "session_id is required" if session_id.nil? || session_id.to_s.empty?

      params = {}
      params[:signal] = signal if signal && !signal.to_s.empty?
      params[:timeout] = timeout if timeout && !timeout.to_s.empty?
      response = http_post_stream(
        Routes.session_kill(sprite_name, session_id),
        nil,
        params: params,
        json: false
      )
      SessionKillStream.new(parse_stream_response!(response))
    end
  end

  class Sprite
    def list_sessions(timeout: nil)
      client.list_sessions(name, timeout: timeout)
    end

    def attach_session(session_id, tty: false)
      client.attach_session(name, session_id, org: org, tty: tty)
    end

    def kill_session(session_id, signal: "TERM", timeout: nil)
      client.kill_session(name, session_id, signal:, timeout:)
    end
  end
end
