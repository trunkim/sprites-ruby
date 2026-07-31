# frozen_string_literal: true

module Sprites
  # Sprite 实例句柄
  #
  # 代表一个远程 Sprite 实例。不会自动创建服务端资源，
  # 只是提供操作该 sprite 的接口（命令执行、文件系统、服务管理等）。
  #
  # 通过 Client#sprite(name) 获取：
  #   sprite = client.sprite("my-sprite")
  #   sprite.command("echo", "hello").output
  class Sprite
    # @return [String] sprite 名称
    attr_reader :name
    # @return [Client] 关联的客户端
    attr_reader :client
    # @return [OrganizationInfo, nil] 组织信息
    attr_reader :org

    # 来自 API 响应的详细字段
    attr_accessor :id, :organization_name, :status, :config, :environment,
                  :created_at, :updated_at, :bucket_name, :primary_region,
                  :url, :url_settings, :version, :environment_version,
                  :labels, :last_running_at, :last_warming_at,
                  :use_legacy_exec_endpoint

    def initialize(name:, client:, org: nil)
      @name = name
      @client = client
      @org = org

      @use_legacy_exec_endpoint = false  # 404 时降级为 legacy 格式
      @supports_control = false           # 是否支持控制连接
      @control_checked = false            # 是否已检测过控制连接
    end

    # 创建一个在此 sprite 上执行的命令
    # @param name [String] 命令名（如 "echo"）
    # @param args [Array<String>] 命令参数
    # @return [Cmd]
    def command(name, *args)
      Cmd.new(sprite: self, name: name, args: args)
    end

    # 创建带 context 的命令（用于取消/超时）
    def command_context(ctx, name, *args)
      Cmd.new(sprite: self, name: name, args: args, ctx: ctx)
    end

    # 销毁此 sprite
    def destroy
      delete
    end

    # 删除此 sprite
    def delete
      client.delete_sprite(name)
    end

    # 升级此 sprite 到最新版本
    def upgrade(ctx = nil)
      client.upgrade_sprite(name)
    end

    def restart
      client.restart_sprite(name)
    end

    def check
      client.check_sprite(name)
    end

    def update(url_settings: nil, labels: nil)
      client.update_sprite(name, url_settings:, labels:)
    end

    # 更新此 sprite 的 URL 认证设置
    def update_url_settings(settings)
      client.update_url_settings(name, settings)
    end

    # @return [Boolean] 此 sprite 是否支持控制连接
    def supports_control?
      @supports_control
    end

    # @return [Boolean] 是否需要使用 legacy exec 端点格式
    def use_legacy_exec_endpoint?
      @use_legacy_exec_endpoint
    end

    # 延迟检测控制连接支持（首次命令执行时调用；Client#sprite 本身零 I/O）
    # 尝试建立一个控制连接，成功则通过 pool.offer_idle 归还复用。
    def ensure_control_support
      return if @control_checked

      @control_checked = true

      if @client.disable_control?
        Sprites.dbg("sprites: control disabled by client option", sprite: @name)
        return
      end

      pool = @client.get_or_create_pool(@name)
      begin
        conn = pool.dial
        @supports_control = true
        Sprites.dbg("sprites: control supported", sprite: @name)
        pool.offer_idle(conn)
      rescue => e
        Sprites.dbg("sprites: control not available", sprite: @name, err: e.message)
        @supports_control = false
      end
    end

    # 从 SpriteInfo 构建 Sprite 实例
    def self.from_info(info, client:, org: nil)
      sprite = new(name: info.name, client: client, org: org)
      sprite.id = info.id
      sprite.organization_name = info.organization
      sprite.status = info.status
      sprite.config = info.config
      sprite.environment = info.environment
      sprite.created_at = info.created_at
      sprite.updated_at = info.updated_at
      sprite.bucket_name = info.bucket_name
      sprite.primary_region = info.primary_region
      sprite.url = info.url
      sprite.url_settings = info.url_settings
      sprite.version = info.version
      sprite.environment_version = info.environment_version
      sprite.labels = info.labels
      sprite.last_running_at = info.last_running_at
      sprite.last_warming_at = info.last_warming_at
      sprite
    end
  end
end
