# frozen_string_literal: true

require "spec_helper"

RSpec.describe "official JS SDK equivalent public surface" do
  let(:client) { Sprites::Client.new("token", base_url: "https://example.test") }
  let(:sprite) { client.sprite("demo") }

  after { client.close }

  it "exposes every management operation" do
    expect(client).to respond_to(
      :create_sprite, :get_sprite, :list_sprites, :watch_sprites, :list_all_sprites,
      :delete_sprite, :upgrade_sprite, :restart_sprite, :check_sprite,
      :update_url_settings, :update_sprite
    )
    expect(Sprites::Client).to respond_to(:create_token)
  end

  it "exposes command, session, checkpoint, service, policy, proxy, and watch operations" do
    expect(sprite).to respond_to(
      :command, :create_session, :attach_session, :list_sessions, :kill_session,
      :exec_file_http, :watch_ports,
      :create_checkpoint, :list_checkpoints, :get_checkpoint, :restore_checkpoint,
      :list_services, :get_service, :create_service, :delete_service,
      :start_service, :stop_service, :restart_service, :get_service_logs, :service_logs, :signal_service,
      :get_network_policy, :update_network_policy,
      :get_privileges_policy, :update_privileges_policy, :delete_privileges_policy,
      :get_resources_policy, :update_resources_policy, :delete_resources_policy,
      :proxy_socket, :proxy_port, :proxy_ports
    )
  end

  it "exposes the complete filesystem operation set" do
    expect(sprite.filesystem).to respond_to(
      :read_file, :write_file, :read_dir, :mkdir, :remove, :stat,
      :rename, :copy, :chmod, :exists?, :chown, :watch,
      :append_file, :read_json, :write_json
    )
  end
end
