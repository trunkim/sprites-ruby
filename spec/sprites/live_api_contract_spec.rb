# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Sprites live filesystem wire contract", :live do
  around do |example|
    WebMock.allow_net_connect!(allow: "api.sprites.dev")
    example.run
  ensure
    WebMock.disable_net_connect!
  end

  it "creates missing parents with mkdirParents and removes through DELETE query params" do
    token = ENV.fetch("SPRITES_LIVE_TOKEN")
    sprite_name = ENV.fetch("SPRITES_LIVE_NAME")
    client = Sprites::Client.new(token)
    filesystem = client.sprite(sprite_name).filesystem_at("/")
    root = "/tmp/sprites-ruby-contract-#{SecureRandom.uuid}"
    file = "#{root}/missing/parents/probe.txt"

    filesystem.write_file(file, "contract-ok", mode: 0o600)
    expect(filesystem.read_file(file)).to eq("contract-ok")

    filesystem.remove(file)
    expect { filesystem.read_file(file) }.to raise_error(Sprites::FSNotFoundError)
  ensure
    filesystem&.remove(root, recursive: true, force: true)
    client&.close
  end
end
