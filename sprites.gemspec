# frozen_string_literal: true

require_relative "lib/sprites/version"

Gem::Specification.new do |spec|
  spec.name = "sprites"
  spec.version = Sprites::VERSION
  spec.authors = ["Sprites Team"]
  spec.summary = "Ruby SDK for the Sprites API"
  spec.description = "An idiomatic Ruby SDK for working with sprites. Execute commands on remote Sprites as if they were local."
  spec.homepage = "https://github.com/trunkim/sprites-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*", "docs/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "logger"
  spec.add_dependency "securerandom"
  spec.add_dependency "uri"
  spec.add_dependency "net-http"
  spec.add_dependency "json"
  spec.add_dependency "openssl"
  spec.add_dependency "base64"

  spec.metadata["rubygems_mfa_required"] = "true"
end
