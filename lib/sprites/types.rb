# frozen_string_literal: true

# 所有 API 数据模型定义
#
# 使用 Ruby 3.2+ 的 Data.define 实现不可变值对象。
# 每个类型都提供 .from_hash(hash) 工厂方法，用于从 API JSON 响应中构建。

require "time"
require "json"

module Sprites
  # Sprite 资源配置（CPU、内存、区域、存储）
  SpriteConfig = Data.define(:ram_mb, :cpus, :region, :storage_gb) do
    def initialize(ram_mb: nil, cpus: nil, region: nil, storage_gb: nil)
      super
    end

    # 序列化为 Hash，仅包含非 nil 字段
    def to_h
      h = {}
      h[:ram_mb] = ram_mb if ram_mb
      h[:cpus] = cpus if cpus
      h[:region] = region if region
      h[:storage_gb] = storage_gb if storage_gb
      h
    end

    # 从 API JSON Hash 构建
    def self.from_hash(hash)
      return nil unless hash

      new(
        ram_mb: hash["ram_mb"],
        cpus: hash["cpus"],
        region: hash["region"],
        storage_gb: hash["storage_gb"]
      )
    end
  end

  # Sprite URL 访问认证设置
  URLSettings = Data.define(:auth, :private_access) do
    def initialize(auth: nil, private_access: nil)
      super
    end

    def to_h
      h = {}
      h[:auth] = auth if auth
      h[:private_access] = private_access if private_access
      h
    end

    def self.from_hash(hash)
      return nil unless hash

      new(auth: hash["auth"], private_access: hash["private_access"])
    end
  end

  # Sprite 完整信息（GET /v1/sprites/{name} 的响应体）
  SpriteInfo = Data.define(
    :id, :name, :organization, :status, :config, :environment,
    :created_at, :updated_at, :bucket_name, :primary_region,
    :url, :url_settings, :labels, :last_running_at, :last_warming_at
  ) do
    def initialize(id: nil, name: nil, organization: nil, status: nil,
                   config: nil, environment: nil, created_at: nil, updated_at: nil,
                   bucket_name: nil, primary_region: nil, url: nil, url_settings: nil,
                   labels: nil, last_running_at: nil, last_warming_at: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        id: hash["id"],
        name: hash["name"],
        organization: hash["organization"],
        status: hash["status"],
        config: SpriteConfig.from_hash(hash["config"]),
        environment: hash["environment"],
        created_at: hash["created_at"] ? Time.parse(hash["created_at"]) : nil,
        updated_at: hash["updated_at"] ? Time.parse(hash["updated_at"]) : nil,
        bucket_name: hash["bucket_name"],
        primary_region: hash["primary_region"],
        url: hash["url"],
        url_settings: URLSettings.from_hash(hash["url_settings"]),
        labels: hash["labels"],
        last_running_at: hash["last_running_at"] ? Time.parse(hash["last_running_at"]) : nil,
        last_warming_at: hash["last_warming_at"] ? Time.parse(hash["last_warming_at"]) : nil
      )
    end
  end

  # 组织级别的汇总统计（包含在 sprite list 响应中）
  OrgInfo = Data.define(:name, :running, :warm, :cold, :running_limit, :warm_limit) do
    def initialize(name: nil, running: 0, warm: 0, cold: 0, running_limit: 0, warm_limit: 0)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        name: hash["name"],
        running: hash["running"] || 0,
        warm: hash["warm"] || 0,
        cold: hash["cold"] || 0,
        running_limit: hash["running_limit"] || 0,
        warm_limit: hash["warm_limit"] || 0
      )
    end
  end

  # Management API 当前声明 max_results 合法范围为 1–50。
  LIST_MAX_RESULTS_MIN = 1
  LIST_MAX_RESULTS_MAX = 50
  LIST_MAX_RESULTS_DEFAULT = LIST_MAX_RESULTS_MAX

  # 列出 sprites 时的分页/过滤选项
  ListOptions = Data.define(:prefix, :max_results, :continuation_token) do
    def initialize(prefix: nil, max_results: LIST_MAX_RESULTS_DEFAULT, continuation_token: nil)
      super(
        prefix: prefix,
        max_results: self.class.clamp_max_results(max_results),
        continuation_token: continuation_token
      )
    end

    def self.clamp_max_results(value)
      n = if value.nil?
        LIST_MAX_RESULTS_DEFAULT
      elsif value.is_a?(Integer)
        value
      elsif value.respond_to?(:to_int)
        value.to_int
      else
        Integer(value, 10)
      end

      unless (LIST_MAX_RESULTS_MIN..LIST_MAX_RESULTS_MAX).cover?(n)
        raise ArgumentError, "max_results must be between #{LIST_MAX_RESULTS_MIN} and #{LIST_MAX_RESULTS_MAX}"
      end

      n
    rescue ArgumentError, TypeError => e
      raise e if e.message.start_with?("max_results must be")

      raise ArgumentError, "max_results must be an integer between #{LIST_MAX_RESULTS_MIN} and #{LIST_MAX_RESULTS_MAX}"
    end
  end

  # 执行会话信息
  #
  # 一个 session 对应一个正在运行或已运行的命令。
  # 活跃的 TTY session 可以通过 attach 重新连接。
  Session = Data.define(:id, :command, :workdir, :created, :bytes_per_second,
                        :is_active, :last_activity, :tty) do
    def initialize(id: nil, command: nil, workdir: nil, created: nil,
                   bytes_per_second: 0.0, is_active: false, last_activity: nil, tty: false)
      super
    end

    # 判断 session 是否仍然活跃（is_active 且最后活动在 5 分钟内）
    def active?
      return false unless is_active
      return is_active unless last_activity

      (Time.now - last_activity) < 300
    end

    # 距离最后活动的时间（秒）
    def activity_age
      ref = last_activity || created
      return 0 unless ref

      Time.now - ref
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        id: hash["id"]&.to_s,
        command: hash["command"]&.to_s,
        workdir: hash["workdir"],
        created: hash["created"] ? Time.parse(hash["created"]) : nil,
        bytes_per_second: hash["bytes_per_second"]&.to_f || 0.0,
        is_active: hash["is_active"] || false,
        last_activity: hash["last_activity"] ? Time.parse(hash["last_activity"]) : nil,
        tty: hash["tty"] || false
      )
    end
  end

  # 命令执行选项（内部使用）
  ExecOptions = Data.define(:working_dir, :environment, :tty, :session_id,
                            :control_mode, :initial_cols, :initial_rows) do
    def initialize(working_dir: nil, environment: nil, tty: false, session_id: nil,
                   control_mode: false, initial_cols: 0, initial_rows: 0)
      super
    end
  end

  # 检查点（snapshot）。list/get 对齐官方字段；create 流终态不解析文本，
  # 调用方用 exact comment 再 list/get 解析唯一结果。
  Checkpoint = Data.define(:id, :create_time, :source_id, :comment, :health, :is_auto) do
    def initialize(id: nil, create_time: nil, source_id: nil, comment: nil, health: nil, is_auto: false)
      super
    end

    def healthy?
      health.nil? || health.to_s.empty? || health.to_s == "healthy"
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        id: hash["id"],
        create_time: hash["create_time"] ? Time.parse(hash["create_time"]) : nil,
        source_id: hash["source_id"],
        comment: hash["comment"],
        health: hash["health"],
        is_auto: hash["is_auto"] || false
      )
    end
  end

  # Privileges policy（capability / device 限制）。
  # 官方 JSON：profile、devices[]、noNewPrivileges（camelCase）。
  PrivilegesPolicy = Data.define(:profile, :devices, :no_new_privileges) do
    PROFILES = [ "", "minimal", "standard", "privileged" ].freeze

    def initialize(profile: nil, devices: nil, no_new_privileges: nil)
      unless profile.nil? || PROFILES.include?(profile.to_s)
        raise ArgumentError, "privileges profile must be one of #{PROFILES.inspect}"
      end

      super(
        profile: profile&.to_s,
        devices: devices.nil? ? nil : Array(devices).map(&:to_s),
        no_new_privileges: no_new_privileges.nil? ? nil : !!no_new_privileges
      )
    end

    def to_h
      h = {}
      h[:profile] = profile unless profile.nil?
      h[:devices] = devices unless devices.nil?
      h[:noNewPrivileges] = no_new_privileges unless no_new_privileges.nil?
      h
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        profile: hash["profile"] || hash[:profile],
        devices: hash.key?("devices") || hash.key?(:devices) ? (hash["devices"] || hash[:devices]) : nil,
        no_new_privileges: if hash.key?("noNewPrivileges")
                             hash["noNewPrivileges"]
                           elsif hash.key?(:no_new_privileges)
                             hash[:no_new_privileges]
                           end
      )
    end
  end

  # Resources policy（memory limits）。
  # 官方 JSON：{ "memory": { "limit_mb": N, "autoscale": bool } }
  ResourcesPolicy = Data.define(:limit_mb, :autoscale) do
    def initialize(limit_mb: nil, autoscale: nil)
      super(
        limit_mb: limit_mb.nil? ? nil : Integer(limit_mb),
        autoscale: autoscale.nil? ? nil : !!autoscale
      )
    end

    def to_h
      return {} if limit_mb.nil? && autoscale.nil?

      memory = {}
      memory[:limit_mb] = limit_mb unless limit_mb.nil?
      memory[:autoscale] = autoscale unless autoscale.nil?
      { memory: memory }
    end

    def self.from_hash(hash)
      return nil unless hash

      memory = hash["memory"] || hash[:memory] || {}
      new(
        limit_mb: memory["limit_mb"] || memory[:limit_mb],
        autoscale: if memory.key?("autoscale")
                     memory["autoscale"]
                   elsif memory.key?(:autoscale)
                     memory[:autoscale]
                   end
      )
    end
  end

  # 流式操作中的消息（checkpoint/restore 流使用）
  # type 可为 "info"、"stdout"、"stderr"、"error"、"complete"
  StreamMessage = Data.define(:type, :data, :error) do
    def initialize(type: nil, data: nil, error: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(type: hash["type"], data: hash["data"], error: hash["error"])
    end
  end

  # 端口事件通知（命令执行时 sprite 内端口打开/关闭的通知）
  PortNotificationMessage = Data.define(:type, :port, :address, :pid) do
    def initialize(type: nil, port: nil, address: nil, pid: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(type: hash["type"], port: hash["port"], address: hash["address"], pid: hash["pid"])
    end
  end

  # 服务定义
  Service = Data.define(:name, :cmd, :args, :env, :dir, :needs, :http_port) do
    def initialize(name: nil, cmd: nil, args: nil, env: nil, dir: nil, needs: nil, http_port: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        name: hash["name"],
        cmd: hash["cmd"],
        args: hash["args"],
        env: hash["env"],
        dir: hash["dir"],
        needs: hash["needs"],
        http_port: hash["http_port"]
      )
    end
  end

  # 服务运行时状态（stopped/starting/running/stopping/failed）
  ServiceState = Data.define(:name, :status, :pid, :started_at, :error,
                             :restart_count, :next_restart_at) do
    def initialize(name: nil, status: nil, pid: nil, started_at: nil,
                   error: nil, restart_count: 0, next_restart_at: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        name: hash["name"],
        status: hash["status"],
        pid: hash["pid"],
        started_at: hash["started_at"] ? Time.parse(hash["started_at"]) : nil,
        error: hash["error"],
        restart_count: hash["restart_count"] || 0,
        next_restart_at: hash["next_restart_at"] ? Time.parse(hash["next_restart_at"]) : nil
      )
    end
  end

  # 服务定义 + 运行时状态的组合
  ServiceWithState = Data.define(:name, :cmd, :args, :env, :dir, :needs, :http_port, :state) do
    def initialize(name: nil, cmd: nil, args: nil, env: nil, dir: nil, needs: nil, http_port: nil, state: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        name: hash["name"],
        cmd: hash["cmd"],
        args: hash["args"],
        env: hash["env"],
        dir: hash["dir"],
        needs: hash["needs"],
        http_port: hash["http_port"],
        state: ServiceState.from_hash(hash["state"])
      )
    end
  end

  # 服务流式日志事件（start/stop/create 操作的实时输出）
  # type: stdout/stderr/exit/error/complete/started/stopping/stopped
  ServiceLogEvent = Data.define(:type, :data, :exit_code, :timestamp, :log_files) do
    def initialize(type: nil, data: nil, exit_code: nil, timestamp: nil, log_files: nil)
      super
    end

    def self.from_hash(hash)
      return nil unless hash

      new(
        type: hash["type"],
        data: hash["data"],
        exit_code: hash["exit_code"],
        timestamp: hash["timestamp"],
        log_files: hash["log_files"]
      )
    end
  end

  # 网络策略规则（允许/拒绝特定域名的出站访问）
  NetworkPolicyRule = Data.define(:domain, :action, :include) do
    def initialize(domain: nil, action: nil, include: nil)
      super
    end

    def to_h
      h = {}
      h[:domain] = domain if domain
      h[:action] = action if action
      h[:include] = self.include if self.include
      h
    end

    def self.from_hash(hash)
      return nil unless hash

      new(domain: hash["domain"], action: hash["action"], include: hash["include"])
    end
  end

  # 网络策略（一组规则）
  NetworkPolicy = Data.define(:rules) do
    def initialize(rules: [])
      super
    end

    def to_h
      { rules: rules.map(&:to_h) }
    end

    def self.from_hash(hash)
      return nil unless hash

      rules = (hash["rules"] || []).map { |r| NetworkPolicyRule.from_hash(r) }
      new(rules: rules)
    end
  end

  # 创建/更新服务时的请求体
  ServiceRequest = Data.define(:cmd, :args, :env, :dir, :needs, :http_port) do
    def initialize(cmd:, args: nil, env: nil, dir: nil, needs: nil, http_port: nil)
      super
    end

    def to_h
      h = { cmd: cmd }
      h[:args] = args if args
      h[:env] = env if env
      h[:dir] = dir if dir
      h[:needs] = needs if needs
      h[:http_port] = http_port if http_port
      h
    end
  end

  # 端口转发映射（本地端口 → 远程端口）
  PortMapping = Data.define(:local_port, :remote_port, :remote_host) do
    def initialize(local_port:, remote_port:, remote_host: nil)
      super
    end
  end

  # 组织信息（附加在 Sprite 上）
  OrganizationInfo = Data.define(:name, :url) do
    def initialize(name: nil, url: nil)
      super
    end
  end
end
