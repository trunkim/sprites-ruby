# frozen_string_literal: true

# 控制连接文件系统操作
#
# 通过控制连接（WebSocket 多路复用）执行文件系统操作，
# 比 REST 方式更快（省去 HTTP 握手开销）。
# 需要 sprite 支持控制连接。
#
# 所有读路径必须走 ControlConn#read_message（单 reader demultiplex queue），
# 禁止直接 conn.ws.read_message，否则会与后台 read_loop 双读竞争。
#
# @example
#   result = sprite.fs_read_control("/etc/hostname")
#   puts result.data
#   sprite.fs_write_control("/tmp/hello.txt", "Hello!")

require "json"
require "uri"

module Sprites
  FsReadResult = Data.define(:path, :size, :data) do
    def initialize(path: nil, size: 0, data: nil)
      super
    end
  end

  FsWriteResult = Data.define(:path, :size, :mode) do
    def initialize(path: nil, size: 0, mode: nil)
      super
    end
  end

  FsListResult = Data.define(:path, :entries, :count) do
    def initialize(path: nil, entries: [], count: 0)
      super
    end
  end

  FsDeleteResult = Data.define(:deleted, :count) do
    def initialize(deleted: [], count: 0)
      super
    end
  end

  FsChmodResult = Data.define(:affected, :count) do
    def initialize(affected: [], count: 0)
      super
    end
  end

  FsChownResult = Data.define(:affected, :count) do
    def initialize(affected: [], count: 0)
      super
    end
  end

  FsCopyResult = Data.define(:copied, :count, :total_bytes) do
    def initialize(copied: [], count: 0, total_bytes: 0)
      super
    end
  end

  FsRenameResult = Data.define(:source, :dest) do
    def initialize(source: nil, dest: nil)
      super
    end
  end

  module FilesystemControl
    def fs_read_control(file_path, working_dir: "/home/sprite", start_byte: nil, end_byte: nil)
      args = { "path" => file_path }
      args["workingDir"] = working_dir if working_dir
      args["start"] = start_byte.to_s if start_byte && start_byte > 0
      args["end"] = end_byte.to_s if end_byte && end_byte > 0

      with_control_conn do |conn|
        send_control_op(conn, "fs.read", args)

        data = read_control_text!(conn)
        check_fs_error!("read", file_path, data)
        result_data = JSON.parse(data)

        msg_type, binary_data = read_control_message!(conn)
        raise Error, "expected binary data" unless msg_type == :binary

        wait_control_complete(conn)
        FsReadResult.new(path: result_data["path"], size: result_data["size"], data: binary_data)
      end
    end

    def fs_write_control(file_path, data, working_dir: "/home/sprite", mode: 0o644, mkdir_parents: true, as_root: false)
      args = { "path" => file_path }
      args["workingDir"] = working_dir if working_dir
      args["mode"] = format("%04o", mode)
      args["mkdirParents"] = "false" unless mkdir_parents
      args["asRoot"] = "true" if as_root

      with_control_conn do |conn|
        send_control_op(conn, "fs.write", args)
        conn.ws.write_binary(data.b)

        resp_data = read_control_text!(conn)
        check_fs_error!("write", file_path, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)
        FsWriteResult.new(path: result["path"], size: result["size"], mode: result["mode"])
      end
    end

    def fs_list_control(dir_path, working_dir: "/home/sprite", recursive: false)
      args = {}
      args["path"] = dir_path if dir_path && !dir_path.empty?
      args["workingDir"] = working_dir if working_dir
      args["recursive"] = "true" if recursive

      with_control_conn do |conn|
        send_control_op(conn, "fs.list", args)

        resp_data = read_control_text!(conn)
        check_fs_error!("list", dir_path, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)

        entries = (result["entries"] || []).map { |e| FSEntry.new(e) }
        FsListResult.new(path: result["path"], entries: entries, count: result["count"] || 0)
      end
    end

    def fs_delete_control(file_path, working_dir: "/home/sprite", recursive: false)
      args = { "path" => file_path }
      args["workingDir"] = working_dir if working_dir
      args["recursive"] = "true" if recursive

      with_control_conn do |conn|
        send_control_op(conn, "fs.delete", args)

        resp_data = read_control_text!(conn)
        check_fs_error!("delete", file_path, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)
        FsDeleteResult.new(deleted: result["deleted"] || [], count: result["count"] || 0)
      end
    end

    def fs_chmod_control(file_path, mode, working_dir: "/home/sprite", recursive: false)
      args = { "path" => file_path, "mode" => format("%04o", mode) }
      args["workingDir"] = working_dir if working_dir
      args["recursive"] = "true" if recursive

      with_control_conn do |conn|
        send_control_op(conn, "fs.chmod", args)

        resp_data = read_control_text!(conn)
        check_fs_error!("chmod", file_path, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)
        FsChmodResult.new(affected: result["affected"] || [], count: result["count"] || 0)
      end
    end

    def fs_chown_control(file_path, working_dir: "/home/sprite", uid: nil, gid: nil, recursive: false)
      raise Error, "at least one of uid or gid must be set" if uid.nil? && gid.nil?

      args = { "path" => file_path }
      args["workingDir"] = working_dir if working_dir
      args["uid"] = uid.to_s if uid
      args["gid"] = gid.to_s if gid
      args["recursive"] = "true" if recursive

      with_control_conn do |conn|
        send_control_op(conn, "fs.chown", args)

        resp_data = read_control_text!(conn)
        check_fs_error!("chown", file_path, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)
        FsChownResult.new(affected: result["affected"] || [], count: result["count"] || 0)
      end
    end

    def fs_copy_control(source, dest, working_dir: "/home/sprite", recursive: false, preserve_attrs: false, as_root: false)
      args = { "source" => source, "dest" => dest }
      args["workingDir"] = working_dir if working_dir
      args["recursive"] = "true" if recursive
      args["preserveAttrs"] = "true" if preserve_attrs
      args["asRoot"] = "true" if as_root

      with_control_conn do |conn|
        send_control_op(conn, "fs.copy", args)

        resp_data = read_control_text!(conn)
        check_fs_error!("copy", source, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)
        FsCopyResult.new(
          copied: result["copied"] || [],
          count: result["count"] || 0,
          total_bytes: result["totalBytes"] || 0
        )
      end
    end

    def fs_rename_control(source, dest, working_dir: "/home/sprite")
      args = { "source" => source, "dest" => dest }
      args["workingDir"] = working_dir if working_dir

      with_control_conn do |conn|
        send_control_op(conn, "fs.rename", args)

        resp_data = read_control_text!(conn)
        check_fs_error!("rename", source, resp_data)

        result = JSON.parse(resp_data)
        wait_control_complete(conn)
        FsRenameResult.new(source: result["source"], dest: result["dest"])
      end
    end

    def fs_stat_control(file_path, working_dir: "/home/sprite")
      result = fs_list_control(file_path, working_dir: working_dir)
      raise FSNotFoundError.new("stat", file_path) if result.entries.empty?

      result.entries.first
    end

    private

    def with_control_conn
      conn = checkout_control_conn
      yield conn
    ensure
      checkin_control_conn(conn) if conn
    end

    def checkout_control_conn
      raise Error, "sprite does not support control connections" unless supports_control?

      pool = client.get_or_create_pool(name)
      pool.checkout
    end

    def checkin_control_conn(conn)
      return unless conn

      conn.send_release rescue nil
      pool = client.get_or_create_pool(name)
      pool.checkin(conn)
    end

    def send_control_op(conn, op, args)
      encoded = URI.encode_www_form(args)
      msg = { type: "op.start", op: op, args: encoded }
      conn.ws.write_text(JSON.generate(msg))
    end

    # 从 demultiplex queue 读下一条消息；禁止直读 WebSocket。
    def read_control_message!(conn, timeout: nil)
      msg = conn.read_message(timeout: timeout)
      raise Error, "failed to read control message" unless msg

      msg
    end

    def read_control_text!(conn, timeout: nil)
      msg_type, data = read_control_message!(conn, timeout: timeout)
      raise Error, "expected text control message, got #{msg_type}" unless msg_type == :text

      data
    end

    def wait_control_complete(conn)
      loop do
        msg_type, data = read_control_message!(conn)
        next unless msg_type == :text

        msg = JSON.parse(data) rescue next
        case msg["type"]
        when "op.complete"
          return
        when "op.error"
          err_args = msg["args"].is_a?(String) ? (JSON.parse(msg["args"]) rescue {}) : (msg["args"] || {})
          raise Error, "operation failed: #{err_args['error'] || 'unknown'}"
        end
      end
    end

    def check_fs_error!(op, path, data)
      parsed = JSON.parse(data) rescue nil
      return unless parsed

      if parsed["error"]
        code = parsed["code"]
        raise FSError.new(op, path, "#{parsed['error']} (#{code})")
      end
    end
  end

  class Sprite
    include FilesystemControl
  end
end
