# frozen_string_literal: true

module Sprites
  # Sprites 请求的进程级 attribution headers。
  #
  # 与官方 JS SDK 一致，检测结果在第一次使用时固定；调用方每次拿到独立 Hash，
  # 不能修改全局缓存。SPRITES_CLIENT_SIGNALS 可关闭环境信号，但仍保留 SDK User-Agent。
  module ClientSignals
    DISABLE_VALUES = %w[0 off false no disabled].freeze
    INVOKED_BY_PATTERN = /\A[a-z0-9][a-z0-9-]{0,63}\z/

    KNOWN_MARKERS = [
      [ "claude-code", "CLAUDECODE", :values, [ "1" ] ],
      [ "claude-code", "CLAUDE_CODE_ENTRYPOINT", :presence, nil ],
      [ "pi", "PI_CODING_AGENT", :values, [ "true" ] ],
      [ "openclaw", "OPENCLAW_SHELL", :values, [ "exec" ] ],
      [ "openclaw", "OPENCLAW_CLI", :values, [ "1" ] ],
      [ "goose", "GOOSE_TERMINAL", :values, [ "1" ] ],
      [ "hermes", "HERMES_SESSION_ID", :presence, nil ],
      [ "codex", "CODEX_SANDBOX", :presence, nil ],
      [ "codex", "CODEX_THREAD_ID", :presence, nil ],
      [ "cursor", "CURSOR_TRACE_ID", :presence, nil ],
      [ "cursor", "CURSOR_AGENT", :presence, nil ],
      [ "gemini-cli", "GEMINI_CLI", :presence, nil ],
      [ "kiro", "TERM_PROGRAM", :values, [ "kiro" ] ],
      [ "antigravity", "ANTIGRAVITY_AGENT", :presence, nil ],
      [ "augment", "AUGMENT_AGENT", :presence, nil ],
      [ "replit", "REPL_ID", :presence, nil ],
      [ "opencode", "OPENCODE", :presence, nil ],
      [ "opencode", "OPENCODE_CALLER", :presence, nil ],
      [ "opencode", "OPENCODE_CLIENT", :presence, nil ],
      [ "copilot", "COPILOT_MODEL", :presence, nil ],
      [ "copilot", "COPILOT_ALLOW_ALL", :presence, nil ],
      [ "kilo-code", "KILO_PLATFORM", :values, [ "vscode" ] ],
      [ "grok", "GROK_AGENT", :values, [ "1" ] ]
    ].freeze

    @mutex = Mutex.new
    @cached_headers = nil

    module_function

    def headers
      @mutex.synchronize { @cached_headers ||= compute_headers }.dup
    end

    def auth_headers(token, extra = {})
      headers.merge("Authorization" => "Bearer #{token}").merge(extra)
    end

    # 仅供测试在隔离的 ENV 场景之间重置 process-wide cache。
    def reset_for_test!
      @mutex.synchronize { @cached_headers = nil }
    end

    def compute_headers
      user_agent = "sprites-ruby/#{VERSION}"
      return { "User-Agent" => user_agent }.freeze if signals_disabled?

      signals = detect
      headers = {
        "Fly-Client-Interactive" => signals.fetch(:interactive).to_s,
        "Fly-Client-Parent" => signals.fetch(:parent)
      }
      if signals[:agent]
        headers["Fly-Client-Agent"] = signals.fetch(:agent)
        headers["Fly-Client-Agent-Source"] = signals.fetch(:agent_source)
      end
      headers["Fly-Client-CI"] = "true" if signals[:ci]

      suffix = "interactive=#{signals.fetch(:interactive)}; parent=#{signals.fetch(:parent)}"
      suffix += "; agent=#{signals.fetch(:agent)}" if signals[:agent]
      headers["User-Agent"] = "#{user_agent} (#{suffix})"
      headers.freeze
    end
    private_class_method :compute_headers

    def signals_disabled?
      DISABLE_VALUES.include?(ENV.fetch("SPRITES_CLIENT_SIGNALS", "").strip.downcase)
    end
    private_class_method :signals_disabled?

    def detect
      agent, source = detect_agent
      {
        interactive: $stdout.tty?,
        parent: parent_bucket,
        agent: agent,
        agent_source: source,
        ci: ENV.key?("CI") || ENV.key?("GITHUB_ACTIONS")
      }
    end
    private_class_method :detect

    def detect_agent
      if ENV.key?("FLY_INVOKED_BY") && (agent = sanitize_agent(ENV["FLY_INVOKED_BY"]))
        return [ agent, "env:FLY_INVOKED_BY" ]
      end

      KNOWN_MARKERS.each do |agent, name, kind, values|
        next unless ENV.key?(name)
        next if kind == :values && !values.include?(ENV[name])

        return [ agent, "env:#{name}" ]
      end

      if ENV.key?("AGENT") && (agent = sanitize_agent(ENV["AGENT"]))
        return [ agent, "env:AGENT" ]
      end

      [ nil, nil ]
    end
    private_class_method :detect_agent

    def sanitize_agent(value)
      candidate = value.to_s.strip.downcase
      candidate if INVOKED_BY_PATTERN.match?(candidate)
    end
    private_class_method :sanitize_agent

    def parent_bucket
      parent_name = if RUBY_PLATFORM.include?("linux")
        File.read("/proc/#{Process.ppid}/comm", mode: "r:UTF-8").strip
      end
      classify_parent_name(parent_name)
    rescue SystemCallError, IOError
      "other"
    end
    private_class_method :parent_bucket

    def classify_parent_name(raw_name)
      name = File.basename(raw_name.to_s.downcase).sub(/\.exe\z/, "")
      return "node" if name == "node"
      return "python" if %w[python python2 python3].include?(name)
      return "shell" if %w[bash zsh fish sh dash ksh tcsh csh cmd powershell pwsh].include?(name)

      "other"
    end
    private_class_method :classify_parent_name
  end
end
