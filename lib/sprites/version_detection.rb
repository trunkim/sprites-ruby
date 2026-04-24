# frozen_string_literal: true

module Sprites
  # 服务端版本检测与功能兼容性判断
  #
  # 通过解析 Sprite-Version 响应头中的语义化版本号，
  # 判断服务端是否支持特定功能（如 path-based attach 端点）。
  #
  # 版本通道分三类：
  # - "dev"     开发版（如 0.0.1-dev-abc123），总是支持最新功能
  # - "rc"      候选版（如 0.0.1-rc30），需要比对最低版本号
  # - "release" 正式版（如 1.0.0），总是支持所有稳定功能
  module VersionDetection
    # path-based attach（/exec/:id）要求的最低 RC 版本
    ATTACH_PATH_MIN_RC = "0.0.1-rc30"

    # 从版本字符串中提取发布通道
    # @param version [String] 如 "v0.0.1-rc30"、"1.0.0-dev-abc"
    # @return [String] "dev"、"rc" 或 "release"
    def self.extract_channel(version)
      v = version.sub(/\Av/, "")

      return "dev" if v.include?("-dev-") || v.end_with?("-dev")

      match = v.match(/-([a-zA-Z]+)\d*\z/)
      if match
        suffix = match[1]
        return "dev" if suffix.start_with?("dev")
        return "rc" if suffix.start_with?("rc")

        return suffix
      end

      "release"
    end

    # 判断服务端是否支持 path-based attach 端点（/exec/:session_id）
    # - dev 版本始终支持
    # - release 版本始终支持
    # - RC 版本需要 >= rc30
    # @param version [String, nil] Sprite-Version 头的值
    # @return [Boolean]
    def self.supports_path_attach?(version)
      return false if version.nil? || version.empty?

      channel = extract_channel(version)
      return true if channel == "dev"

      v = parse_version(version.sub(/\Av/, ""))
      return false unless v

      if channel == "rc"
        min = parse_version(ATTACH_PATH_MIN_RC)
        return compare_versions(v, min) >= 0
      end

      # release 版本
      true
    end

    # 解析版本字符串为 {major:, minor:, patch:, pre:} 结构
    def self.parse_version(str)
      base, pre = str.split("-", 2)
      parts = base.split(".").map(&:to_i)
      { major: parts[0] || 0, minor: parts[1] || 0, patch: parts[2] || 0, pre: pre }
    end

    # 比较两个解析后的版本，返回 -1/0/1
    def self.compare_versions(a, b)
      [:major, :minor, :patch].each do |field|
        cmp = (a[field] || 0) <=> (b[field] || 0)
        return cmp unless cmp == 0
      end

      return 0 if a[:pre] == b[:pre]
      # 没有 pre-release 标记的版本 > 有标记的
      return 1 if a[:pre].nil?
      return -1 if b[:pre].nil?

      compare_prerelease(a[:pre], b[:pre])
    end

    # 比较 pre-release 标识符（如 "rc30" vs "rc31"）
    def self.compare_prerelease(a, b)
      a_parts = split_prerelease(a)
      b_parts = split_prerelease(b)

      [a_parts.length, b_parts.length].max.times do |i|
        return -1 if i >= a_parts.length
        return 1 if i >= b_parts.length

        ai, bi = a_parts[i], b_parts[i]
        if ai.is_a?(Integer) && bi.is_a?(Integer)
          cmp = ai <=> bi
        else
          cmp = ai.to_s <=> bi.to_s
        end
        return cmp unless cmp == 0
      end

      0
    end

    # 将 pre-release 字符串拆分为数字和字母段，数字转为 Integer
    def self.split_prerelease(pre)
      pre.scan(/\d+|[a-zA-Z]+/).map { |p| p.match?(/\A\d+\z/) ? p.to_i : p }
    end
  end
end
