# frozen_string_literal: true

# REST 文件系统操作
#
# 通过 HTTP REST 端点操作 sprite 内的文件系统。
# 支持读写文件、列目录、删除、重命名、复制、权限修改等。
#
# @example
#   fs = sprite.filesystem
#   data = fs.read_file("/etc/hostname")
#   fs.write_file("/tmp/hello.txt", "Hello!", mode: 0o644)
#   entries = fs.read_dir("/tmp")

require "json"
require "net/http"

module Sprites
  class SpriteFS
    def initialize(sprite:, working_dir: "/")
      @sprite = sprite
      @working_dir = working_dir
    end

    def read_file(name)
      resp = http_get("/read", path: name, workingDir: @working_dir)
      raise_fs_error!("read", name, resp) unless [200, 206].include?(resp.code.to_i)

      resp.body
    end

    def write_file(name, data, mode: 0o644, mkdir_parents: true)
      resp = http_put_binary(
        "/write",
        data,
        path: name,
        workingDir: @working_dir,
        mode: format("%04o", mode),
        mkdirParents: mkdir_parents ? "true" : "false"
      )
      raise_fs_error!("write", name, resp) unless [200, 201].include?(resp.code.to_i)
    end

    def read_dir(name, recursive: false, pattern: nil)
      params = { path: name, workingDir: @working_dir }
      params[:recursive] = "true" if recursive
      params[:pattern] = pattern if pattern
      resp = http_get("/list", **params)
      raise_fs_error!("readdir", name, resp) unless resp.code.to_i == 200

      data = JSON.parse(resp.body)
      (data["entries"] || []).map { |e| FSEntry.new(e) }
    end

    def stat(name)
      resp = http_get("/list", path: name, workingDir: @working_dir)
      raise_fs_error!("stat", name, resp) unless resp.code.to_i == 200

      data = JSON.parse(resp.body)
      entries = data["entries"] || []
      raise FSNotFoundError.new("stat", name) if entries.empty?

      FSEntry.new(entries.first)
    end

    def mkdir(name, mode: 0o755, recursive: true)
      keep_path = name.to_s.end_with?("/") ? "#{name}.keep" : "#{name}/.keep"
      write_file(keep_path, "", mode: mode, mkdir_parents: recursive)
      begin
        remove(keep_path)
      rescue StandardError
        # 目录已经创建成功；清理占位文件失败不应把 mkdir 误报为失败。
        nil
      end
    end

    def mkdir_all(name, mode: 0o755)
      mkdir(name, mode: mode, recursive: true)
    end

    def remove(name, recursive: false, force: false, as_root: false)
      params = { path: name, workingDir: @working_dir }
      params[:recursive] = "true" if recursive
      params[:asRoot] = "true" if as_root
      resp = http_delete("/delete", **params)
      return if success?(resp) || (force && resp.code.to_i == 404)

      raise_fs_error!("remove", name, resp)
    end

    def remove_all(name, force: false, as_root: false)
      remove(name, recursive: true, force: force, as_root: as_root)
    end

    def rename(old_name, new_name, as_root: false)
      body = { source: old_name, dest: new_name, workingDir: @working_dir }
      body[:asRoot] = true if as_root
      resp = http_post_json("/rename", body)
      raise_fs_error!("rename", old_name, resp) unless success?(resp)
    end

    def copy(src, dst, recursive: true, preserve_attrs: false, as_root: false)
      body = {
        source: src,
        dest: dst,
        workingDir: @working_dir,
        recursive: recursive,
        preserveAttrs: preserve_attrs,
        asRoot: as_root
      }
      resp = http_post_json("/copy", body)
      raise_fs_error!("copy", src, resp) unless success?(resp)
    end

    def chmod(name, mode, recursive: false, as_root: false)
      body = {
        path: name,
        workingDir: @working_dir,
        mode: format("%04o", mode & 0o777),
        recursive: recursive,
        asRoot: as_root
      }
      resp = http_post_json("/chmod", body)
      raise_fs_error!("chmod", name, resp) unless success?(resp)
    end

    def chown(name, uid: nil, gid: nil, recursive: false, as_root: false)
      raise ArgumentError, "uid or gid is required" if uid.nil? && gid.nil?

      body = {
        path: name,
        workingDir: @working_dir,
        uid: uid,
        gid: gid,
        recursive: recursive,
        asRoot: as_root
      }.compact
      resp = http_post_json("/chown", body)
      raise_fs_error!("chown", name, resp) unless success?(resp)
    end

    def exists?(name)
      stat(name)
      true
    rescue FSNotFoundError
      false
    end

    def append_file(name, data, mode: 0o644)
      current = read_file(name)
      write_file(name, current + data.to_s, mode: mode)
    rescue FSNotFoundError
      write_file(name, data, mode: mode)
    end

    def read_json(name)
      JSON.parse(read_file(name))
    end

    def write_json(name, value, spaces: nil, mode: 0o644)
      content = if spaces.nil? || Integer(spaces).zero?
        JSON.generate(value)
      else
        indent = " " * Integer(spaces)
        JSON.generate(value, indent: indent, space: " ", object_nl: "\n", array_nl: "\n")
      end
      write_file(name, content, mode: mode)
    end

    private

    def base_url
      "#{@sprite.client.base_url}#{Routes.filesystem(@sprite.name)}"
    end

    def http_get(path, **params)
      uri = Routes.uri(base_url, path, params: params)

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"

      perform_request(uri, req)
    end

    def http_delete(path, **params)
      uri = Routes.uri(base_url, path, params: params)

      req = Net::HTTP::Delete.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"

      perform_request(uri, req)
    end

    def http_put_binary(path, data, **params)
      uri = Routes.uri(base_url, path, params: params)

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"
      req["Content-Type"] = "application/octet-stream"
      req.body = data

      perform_request(uri, req)
    end

    def http_post_json(path, body)
      uri = Routes.uri(base_url, path)

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      perform_request(uri, req)
    end

    def perform_request(uri, req)
      @sprite.client.request(uri, req)
    end

    def success?(response)
      response.code.to_i.between?(200, 299)
    end

    def raise_fs_error!(op, path, resp)
      status = resp.code.to_i
      begin
        data = JSON.parse(resp.body)
        if status == 404 || data["code"] == "ENOENT"
          raise FSNotFoundError.new(
            op,
            data["path"] || path,
            message: data["error"],
            status_code: status
          )
        end
        if data["error"]
          raise FSError.new(
            op,
            data["path"] || path,
            data["error"],
            code: data["code"],
            status_code: status
          )
        end
      rescue JSON::ParserError
        # ignore
      end

      raise FSNotFoundError.new(op, path, status_code: status) if status == 404

      raise FSError.new(op, path, "HTTP #{resp.code}", status_code: status)
    end
  end

  class FSEntry
    attr_reader :name, :path, :type, :size, :mode, :mod_time, :dir

    def initialize(hash)
      @name = hash["name"]
      @path = hash["path"]
      @type = hash["type"]
      @size = hash["size"] || 0
      @mode = hash["mode"]
      @mod_time = hash["modTime"] ? Time.parse(hash["modTime"]) : nil
      @dir = hash["isDir"] || false
    end

    alias dir? dir

    def file? = !dir? && type != "symlink"
    def symlink? = type == "symlink"

    def mode_value
      return mode if mode.is_a?(Integer)

      mode.to_s.to_i(8)
    end
  end

  class FSError < Error
    attr_reader :op, :path, :code, :status_code

    def initialize(op, path, message, code: nil, status_code: nil)
      @op = op
      @path = path
      @code = code || "UNKNOWN"
      @status_code = status_code
      super("#{op} #{path}: #{message}")
    end
  end

  class FSNotFoundError < FSError
    def initialize(op, path, message: nil, status_code: 404)
      super(op, path, message || "file not found", code: "ENOENT", status_code: status_code)
    end
  end

  class Sprite
    def filesystem
      SpriteFS.new(sprite: self)
    end

    def filesystem_at(working_dir)
      SpriteFS.new(sprite: self, working_dir: working_dir)
    end
  end
end
