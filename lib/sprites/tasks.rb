# frozen_string_literal: true

require 'json'
require 'shellwords'

module Sprites
  # Tasks API —— 把 Sprite 保持在 active 状态的 hold。
  #
  # Sprite 空闲约 30 秒就会 warm 暂停（连接断开、进程冻结），空闲更久转 cold。
  # agent / queue worker 在两次工作之间等待时，必须显式 hold 才能避免中途暂停。
  # 一次 hold 最长 1 小时，更长的工作用短过期 + 定时 upsert 续期。
  #
  # Tasks API 只存在于 sprite 内的 management socket（/.sprite/api.sock），
  # 因此经 exec 调用 `sprite-env curl`；这不是公开 REST 面。
  module Tasks
    MANAGEMENT_TIMEOUT = 30
    MAX_EXPIRE_SECONDS = 3600
    DURATION_PATTERN = /\A(\d+)(s|m|h)\z/
    DURATION_FACTORS = { 's' => 1, 'm' => 60, 'h' => 3600 }.freeze

    # @return [Array<SpriteTask>]
    def list_tasks(sprite_name)
      payload = task_request(sprite_name, method: 'GET', path: '/v1/tasks')
      Array(payload['tasks']).filter_map { |task| SpriteTask.from_hash(task) }
    end

    # @return [SpriteTask, nil] 任务不存在时返回 nil
    def get_task(sprite_name, name)
      payload = task_request(
        sprite_name,
        method: 'GET',
        path: "/v1/tasks/#{task_segment(name)}",
        allow_not_found: true
      )
      payload && SpriteTask.from_hash(payload)
    end

    # 创建或续期（PUT 幂等 upsert）。
    #
    # @param expire [Integer, String] 秒数或 "30s" / "5m" / "1h"，上限 1 小时
    # @return [SpriteTask]
    def upsert_task(sprite_name, name:, expire:)
      normalized = normalize_expire(expire)
      payload = task_request(
        sprite_name,
        method: 'PUT',
        path: "/v1/tasks/#{task_segment(name)}",
        body: { expire: normalized }
      )
      SpriteTask.from_hash(payload)
    end

    # 幂等删除；任务已过期或不存在时同样返回 true。
    def delete_task(sprite_name, name:)
      task_request(
        sprite_name,
        method: 'DELETE',
        path: "/v1/tasks/#{task_segment(name)}",
        allow_not_found: true
      )
      true
    end

    private

    def task_segment(name)
      name = name.to_s
      raise ArgumentError, 'task name is required' if name.empty?

      URI.encode_uri_component(name)
    end

    def normalize_expire(expire)
      seconds = case expire
                when Integer then expire
                when String
                  match = DURATION_PATTERN.match(expire)
                  raise ArgumentError, 'expire must be seconds or a duration like 30m/1h' unless match

                  match[1].to_i * { 's' => 1, 'm' => 60, 'h' => 3600 }.fetch(match[2])
                else
                  raise ArgumentError, 'expire must be an Integer or a duration string'
                end
      raise ArgumentError, 'expire must be between 1s and 1h (max 3600s)' unless seconds.between?(1, MAX_EXPIRE_SECONDS)

      expire
    end

    def task_request(sprite_name, method:, path:, body: nil, allow_not_found: false)
      args = [
        'sprite-env', 'curl', '-sS', '-f', '-X', method,
        '-H', 'Content-Type: application/json'
      ]
      args += ['-d', JSON.generate(body)] if body
      args << "http://sprite#{path}"

      result = exec_file_http(
        sprite_name, '/bin/sh', ['-lc', args.shelljoin], timeout: MANAGEMENT_TIMEOUT
      )
      raw = result.stdout.to_s.strip
      raw.empty? ? {} : JSON.parse(raw)
    rescue ExecError => e
      return nil if allow_not_found && task_not_found?(e)

      raise
    end

    def parse_task_body(raw)
      raw = raw.to_s.strip
      raw.empty? ? {} : JSON.parse(raw)
    end

    def task_not_found?(error)
      error.result.stderr.to_s.include?('404')
    end
  end
end
