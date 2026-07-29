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
      resp = http_get("/fs/read", path: name, workingDir: @working_dir)
      raise_fs_error!("read", name, resp) unless [200, 206].include?(resp.code.to_i)

      resp.body
    end

    def write_file(name, data, mode: 0o644)
      resp = http_put_binary(
        "/fs/write",
        data,
        path: name,
        workingDir: @working_dir,
        mode: format("%04o", mode),
        mkdirParents: "true"
      )
      raise_fs_error!("write", name, resp) unless [200, 201].include?(resp.code.to_i)
    end

    def read_dir(name)
      resp = http_get("/fs/list", path: name, workingDir: @working_dir)
      raise_fs_error!("readdir", name, resp) unless resp.code.to_i == 200

      data = JSON.parse(resp.body)
      (data["entries"] || []).map { |e| FSEntry.new(e) }
    end

    def stat(name)
      resp = http_get("/fs/list", path: name, workingDir: @working_dir)
      raise_fs_error!("stat", name, resp) unless resp.code.to_i == 200

      data = JSON.parse(resp.body)
      entries = data["entries"] || []
      raise FSNotFoundError.new("stat", name) if entries.empty?

      FSEntry.new(entries.first)
    end

    def mkdir(name, mode: 0o755)
      write_file("#{name}/.keep", "", mode: mode)
    end

    def mkdir_all(name, mode: 0o755)
      mkdir(name, mode: mode)
    end

    def remove(name)
      resp = http_delete("/fs/delete", path: name, workingDir: @working_dir)
      raise_fs_error!("remove", name, resp) unless resp.code.to_i == 200
    end

    def remove_all(name)
      resp = http_delete("/fs/delete", path: name, workingDir: @working_dir, recursive: "true")
      raise_fs_error!("remove", name, resp) unless resp.code.to_i == 200
    end

    def rename(old_name, new_name)
      body = { source: old_name, dest: new_name, workingDir: @working_dir }
      resp = http_post_json("/fs/rename", body)
      raise_fs_error!("rename", old_name, resp) unless resp.code.to_i == 200
    end

    def copy(src, dst)
      body = { source: src, dest: dst, workingDir: @working_dir, recursive: true }
      resp = http_post_json("/fs/copy", body)
      raise_fs_error!("copy", src, resp) unless resp.code.to_i == 200
    end

    def chmod(name, mode)
      body = { path: name, workingDir: @working_dir, mode: format("%04o", mode & 0o777) }
      resp = http_post_json("/fs/chmod", body)
      raise_fs_error!("chmod", name, resp) unless resp.code.to_i == 200
    end

    private

    def base_url
      "#{@sprite.client.base_url}/v1/sprites/#{@sprite.name}"
    end

    def http_get(path, **params)
      uri = URI("#{base_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"

      perform_request(uri, req)
    end

    def http_delete(path, **params)
      uri = URI("#{base_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?

      req = Net::HTTP::Delete.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"

      perform_request(uri, req)
    end

    def http_put_binary(path, data, **params)
      uri = URI("#{base_url}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?

      req = Net::HTTP::Put.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"
      req["Content-Type"] = "application/octet-stream"
      req.body = data

      perform_request(uri, req)
    end

    def http_post_json(path, body)
      uri = URI("#{base_url}#{path}")

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@sprite.client.token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      perform_request(uri, req)
    end

    def perform_request(uri, req)
      @sprite.client.request(uri, req)
    end

    def raise_fs_error!(op, path, resp)
      status = resp.code.to_i
      if status == 404
        raise FSNotFoundError.new(op, path, status_code: status)
      end

      begin
        data = JSON.parse(resp.body)
        if data["error"]
          raise FSError.new(op, path, data["error"], status_code: status)
        end
      rescue JSON::ParserError
        # ignore
      end

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
  end

  class FSError < Error
    attr_reader :op, :path, :status_code

    def initialize(op, path, message, status_code: nil)
      @op = op
      @path = path
      @status_code = status_code
      super("#{op} #{path}: #{message}")
    end
  end

  class FSNotFoundError < FSError
    def initialize(op, path, status_code: 404)
      super(op, path, "file not found", status_code: status_code)
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
