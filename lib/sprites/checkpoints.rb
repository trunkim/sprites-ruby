# frozen_string_literal: true

# 检查点（Checkpoint）管理
#
# 检查点是 sprite 的快照，可用于备份和恢复状态。
# 创建和恢复操作返回流式响应（CheckpointStream / RestoreStream）。
# create 的 terminal 文本不可靠；调用方用 exact comment 再 list/get 解析唯一 typed 结果。

require "json"

module Sprites
  module Checkpoints
    def create_checkpoint(sprite_name, comment: nil)
      payload = {}
      payload[:comment] = comment if comment && !comment.empty?

      resp = http_post_stream(Routes.checkpoint_create(sprite_name), payload)
      CheckpointStream.new(parse_stream_response!(resp, expected: [200, 201]))
    end

    # 消费 create 流并校验 error/complete 终态；不从 terminal 文本解析 checkpoint id。
    def create_checkpoint!(sprite_name, comment:)
      raise ArgumentError, "comment is required for correlation" if comment.nil? || comment.to_s.empty?

      stream = create_checkpoint(sprite_name, comment: comment)
      stream.drain!
      find_checkpoint_by_comment!(sprite_name, comment)
    end

    def list_checkpoints(sprite_name, history_filter: nil, include_auto: false)
      params = {}
      params["history"] = history_filter if history_filter
      params["includeAuto"] = "true" if include_auto

      resp = http_get(Routes.checkpoints(sprite_name), params: params)
      data = parse_response!(resp)

      return data if data.is_a?(String)

      data.map { |c| Checkpoint.from_hash(c) }
    end

    def get_checkpoint(sprite_name, checkpoint_id)
      resp = http_get(Routes.checkpoint(sprite_name, checkpoint_id))
      data = parse_response!(resp)
      Checkpoint.from_hash(data)
    end

    # 按 caller 提供的 exact comment 解析唯一 checkpoint；0 或多于 1 个均 fail closed。
    def find_checkpoint_by_comment!(sprite_name, comment)
      matches = list_checkpoints(sprite_name, include_auto: true).select { |c| c.comment.to_s == comment.to_s }
      if matches.empty?
        raise APIError.new(
          status_code: 404,
          error_code: "not_found",
          message: "checkpoint not found for comment: #{comment}"
        )
      end
      if matches.size > 1
        raise Error, "ambiguous checkpoint comment #{comment.inspect}: #{matches.size} matches"
      end

      matches.first
    end

    def restore_checkpoint(sprite_name, checkpoint_id)
      resp = http_post_stream(Routes.checkpoint_restore(sprite_name, checkpoint_id), nil)
      RestoreStream.new(parse_stream_response!(resp, expected: [200, 201]))
    end

    def delete_checkpoint(sprite_name, checkpoint_id)
      resp = http_delete(Routes.checkpoint(sprite_name, checkpoint_id))
      return if [200, 204].include?(resp.code.to_i)

      parse_response!(resp)
    end
  end

  class Sprite
    def create_checkpoint(comment: nil)
      client.create_checkpoint(name, comment: comment)
    end

    def create_checkpoint!(comment:)
      client.create_checkpoint!(name, comment: comment)
    end

    def list_checkpoints(history_filter: nil, include_auto: false)
      client.list_checkpoints(name, history_filter: history_filter, include_auto: include_auto)
    end

    def get_checkpoint(checkpoint_id)
      client.get_checkpoint(name, checkpoint_id)
    end

    def find_checkpoint_by_comment!(comment)
      client.find_checkpoint_by_comment!(name, comment)
    end

    def restore_checkpoint(checkpoint_id)
      client.restore_checkpoint(name, checkpoint_id)
    end

    def delete_checkpoint(checkpoint_id)
      client.delete_checkpoint(name, checkpoint_id)
    end
  end
end
