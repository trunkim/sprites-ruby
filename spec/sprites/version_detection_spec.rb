# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::VersionDetection do
  describe ".extract_channel" do
    it "returns 'release' for simple versions" do
      expect(described_class.extract_channel("1.0.0")).to eq("release")
      expect(described_class.extract_channel("0.1.0")).to eq("release")
    end

    it "returns 'rc' for RC versions" do
      expect(described_class.extract_channel("0.0.1-rc30")).to eq("rc")
      expect(described_class.extract_channel("v0.0.1-rc1")).to eq("rc")
    end

    it "returns 'dev' for dev versions" do
      expect(described_class.extract_channel("0.0.1-dev")).to eq("dev")
      expect(described_class.extract_channel("0.0.1-dev-abc123")).to eq("dev")
      expect(described_class.extract_channel("v1.0.0-dev1")).to eq("dev")
    end

    it "strips v prefix" do
      expect(described_class.extract_channel("v1.0.0")).to eq("release")
    end
  end

  describe ".supports_path_attach?" do
    it "returns false for empty version" do
      expect(described_class.supports_path_attach?("")).to be false
      expect(described_class.supports_path_attach?(nil)).to be false
    end

    it "returns true for dev versions" do
      expect(described_class.supports_path_attach?("0.0.1-dev-abc")).to be true
    end

    it "returns true for release versions" do
      expect(described_class.supports_path_attach?("1.0.0")).to be true
      expect(described_class.supports_path_attach?("v0.1.0")).to be true
    end

    it "returns true for rc30+" do
      expect(described_class.supports_path_attach?("0.0.1-rc30")).to be true
      expect(described_class.supports_path_attach?("0.0.1-rc31")).to be true
      expect(described_class.supports_path_attach?("0.0.1-rc100")).to be true
    end

    it "returns false for rc29 and below" do
      expect(described_class.supports_path_attach?("0.0.1-rc29")).to be false
      expect(described_class.supports_path_attach?("0.0.1-rc1")).to be false
    end
  end
end
