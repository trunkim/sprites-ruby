# frozen_string_literal: true

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
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 30
      http.read_timeout = 30
      http.request(req)
    end

    def raise_fs_error!(op, path, resp)
      if resp.code.to_i == 404
        raise FSNotFoundError.new(op, path)
      end

      begin
        data = JSON.parse(resp.body)
        if data["error"]
          raise FSError.new(op, path, data["error"])
        end
      rescue JSON::ParserError
        # ignore
      end

      raise FSError.new(op, path, "HTTP #{resp.code}")
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
    attr_reader :op, :path

    def initialize(op, path, message)
      @op = op
      @path = path
      super("#{op} #{path}: #{message}")
    end
  end

  class FSNotFoundError < FSError
    def initialize(op, path)
      super(op, path, "file not found")
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
