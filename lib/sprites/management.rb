# frozen_string_literal: true

require "json"
require "net/http"

module Sprites
  module Management
    def create_sprite(name, config: nil, org: nil, labels: nil)
      body = { name: name }
      body[:config] = config.to_h if config
      body[:labels] = labels if labels

      resp = http_post("/v1/sprites", body)
      data = parse_response!(resp, expected: 201)

      sprite = Sprite.new(name: data["name"] || name, client: self, org: org)
      sprite.status = "created"
      sprite
    end

    def get_sprite(name, org: nil)
      resp = http_get("/v1/sprites/#{name}")

      if resp.code.to_i == 404
        raise Error, "sprite not found: #{name}"
      end

      data = parse_response!(resp)
      info = SpriteInfo.from_hash(data)
      Sprite.from_info(info, client: self, org: org)
    end

    def list_sprites(opts = nil)
      opts ||= ListOptions.new

      params = {}
      params["max_results"] = opts.max_results.to_s if opts.max_results && opts.max_results > 0
      params["continuation_token"] = opts.continuation_token if opts.continuation_token
      params["prefix"] = opts.prefix if opts.prefix

      resp = http_get("/v1/sprites", params: params)
      data = parse_response!(resp)

      sprites = (data["sprites"] || []).map { |s| SpriteInfo.from_hash(s) }
      org_info = OrgInfo.from_hash(data["org"])

      {
        sprites: sprites,
        org: org_info,
        has_more: data["has_more"] || false,
        next_continuation_token: data["next_continuation_token"]
      }
    end

    ListResult = Data.define(:sprites, :org) do
      def initialize(sprites: [], org: nil)
        super
      end
    end

    def list_all_sprites(prefix: nil, org: nil)
      result = list_all_sprites_result(prefix: prefix, org: org)
      result.sprites
    end

    def list_all_sprites_result(prefix: nil, org: nil)
      all_sprites = []
      org_info = nil
      continuation_token = nil

      loop do
        opts = ListOptions.new(
          prefix: prefix,
          max_results: 100,
          continuation_token: continuation_token
        )

        list = list_sprites(opts)
        org_info ||= list[:org]

        list[:sprites].each do |info|
          all_sprites << Sprite.from_info(info, client: self, org: org)
        end

        break unless list[:has_more] && list[:next_continuation_token]

        continuation_token = list[:next_continuation_token]
      end

      ListResult.new(sprites: all_sprites, org: org_info)
    end

    def delete_sprite(name)
      resp = http_delete("/v1/sprites/#{name}")
      return if [200, 204].include?(resp.code.to_i)

      parse_response!(resp)
    end

    alias destroy_sprite delete_sprite

    def upgrade_sprite(name)
      resp = http_post("/v1/sprites/#{name}/upgrade", nil)
      return if [200, 204].include?(resp.code.to_i)

      parse_response!(resp)
    end

    def update_url_settings(sprite_name, settings)
      body = { url_settings: settings.to_h }
      resp = http_put("/v1/sprites/#{sprite_name}", body)
      parse_response!(resp)
    end

    def update_sprite(sprite_name, url_settings: nil, labels: nil, clear_labels: false)
      body = {}
      body[:url_settings] = url_settings.to_h if url_settings
      body[:labels] = labels if labels
      body[:clear_labels] = clear_labels if clear_labels

      resp = http_put("/v1/sprites/#{sprite_name}", body)
      parse_response!(resp)
    end
  end
end
