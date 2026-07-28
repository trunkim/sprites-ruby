# frozen_string_literal: true

# 检查点（Checkpoint）管理
#
# 检查点是 sprite 的快照，可用于备份和恢复状态。
# 创建和恢复操作返回流式响应（CheckpointStream / RestoreStream），
# 可逐行读取进度消息。

require "json"

module Sprites
  module Checkpoints
    def create_checkpoint(sprite_name, comment: nil)
      payload = {}
      payload[:comment] = comment if comment && !comment.empty?

      resp = http_post_stream("/v1/sprites/#{sprite_name}/checkpoint", payload)
      CheckpointStream.new(resp.body)
    end

    def list_checkpoints(sprite_name, history_filter: nil, include_auto: false)
      params = {}
      params["history"] = history_filter if history_filter
      params["includeAuto"] = "true" if include_auto

      resp = http_get("/v1/sprites/#{sprite_name}/checkpoints", params: params)
      data = parse_response!(resp)

      return data if data.is_a?(String)

      data.map { |c| Checkpoint.from_hash(c) }
    end

    def get_checkpoint(sprite_name, checkpoint_id)
      resp = http_get("/v1/sprites/#{sprite_name}/checkpoints/#{checkpoint_id}")
      data = parse_response!(resp)
      Checkpoint.from_hash(data)
    end

    def restore_checkpoint(sprite_name, checkpoint_id)
      resp = http_post_stream("/v1/sprites/#{sprite_name}/checkpoints/#{checkpoint_id}/restore", nil)
      RestoreStream.new(resp.body)
    end

    def delete_checkpoint(sprite_name, checkpoint_id)
      resp = http_delete("/v1/sprites/#{sprite_name}/checkpoints/#{checkpoint_id}")
      return if [200, 204].include?(resp.code.to_i)

      parse_response!(resp)
    end
  end

  class Sprite
    def create_checkpoint(comment: nil)
      client.create_checkpoint(name, comment: comment)
    end

    def list_checkpoints(history_filter: nil, include_auto: false)
      client.list_checkpoints(name, history_filter: history_filter, include_auto: include_auto)
    end

    def get_checkpoint(checkpoint_id)
      client.get_checkpoint(name, checkpoint_id)
    end

    def restore_checkpoint(checkpoint_id)
      client.restore_checkpoint(name, checkpoint_id)
    end

    def delete_checkpoint(checkpoint_id)
      client.delete_checkpoint(name, checkpoint_id)
    end
  end
end
