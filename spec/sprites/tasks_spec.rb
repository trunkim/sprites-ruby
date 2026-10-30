# frozen_string_literal: true

require 'spec_helper'

module TasksSpecSupport
  # HTTP exec 的 frame 边界有语义（stdout/stderr/exit），WebMock 会把 body 合成一个 chunk，
  # 因此这里和 http_exec_spec 一样注入可按 frame 切分的 transport。
  class FakeTasksResponse
    attr_reader :code

    def initialize(chunks)
      @code = '200'
      @chunks = chunks
    end

    def [](name) = name == 'Sprite-Version' ? '0.0.4' : nil

    def read_body(&block) = @chunks.each(&block)
  end

  class FakeTasksTransport
    attr_reader :requests

    def initialize(chunk_lists)
      @chunk_lists = chunk_lists
      @requests = []
    end

    def request(request)
      @requests << request
      response = FakeTasksResponse.new(@chunk_lists.shift || [])
      yield response
      response
    end
  end
end

RSpec.describe Sprites::Tasks do
  def exec_chunks(stdout: '', stderr: '', exit_code: 0)
    chunks = []
    chunks << ("\x01".b + stdout.to_s.b) unless stdout.to_s.empty?
    chunks << ("\x02".b + stderr.to_s.b) unless stderr.to_s.empty?
    chunks << ("\x03".b + exit_code.chr)
    chunks
  end

  def client_for(*chunk_lists)
    transport = TasksSpecSupport::FakeTasksTransport.new(chunk_lists)
    client = Sprites::Client.new(
      'token',
      base_url: 'https://example.test',
      http_client: transport,
      disable_control: true
    )
    [client, transport]
  end

  def management_command(transport)
    URI.decode_www_form(transport.requests.last.uri.query).filter_map { |key, value| value if key == 'cmd' }.last
  end

  after do
    @client&.close
  end

  it 'lists tasks from the sprite management socket' do
    payload = {
      tasks: [
        { name: 'run-1', started_at: '2026-10-30T07:06:04Z', expires_at: '2026-10-30T08:06:04Z' }
      ]
    }
    client, transport = client_for(exec_chunks(stdout: JSON.generate(payload)))
    @client = client

    tasks = client.list_tasks('demo')

    expect(tasks.map(&:name)).to eq(['run-1'])
    expect(tasks.first.expires_at).to eq(Time.utc(2026, 10, 30, 8, 6, 4))
    command = management_command(transport)
    expect(command).to include('sprite-env curl')
    expect(command).to include('-X GET')
    expect(command).to include('http://sprite/v1/tasks')
  end

  it 'upserts with PUT and encodes the task name' do
    payload = { name: 'run-1', started_at: '2026-10-30T07:06:04Z', expires_at: '2026-10-30T07:36:04Z' }
    client, transport = client_for(exec_chunks(stdout: JSON.generate(payload)))
    @client = client

    task = client.upsert_task('demo', name: 'run/1', expire: '30m')

    expect(task.name).to eq('run-1')
    command = management_command(transport)
    expect(command).to include('-X PUT')
    expect(command).to include('http://sprite/v1/tasks/run')
    expect(command).to include('2F1')
    expect(command).to include('30m')
  end

  it 'treats delete of an expired task as success' do
    client, transport = client_for(exec_chunks(stderr: 'curl: (22) The requested URL returned error: 404',
                                               exit_code: 22))
    @client = client

    expect(client.delete_task('demo', name: 'run-1')).to be(true)
    expect(management_command(transport)).to include('-X DELETE')
  end

  it 'returns nil when the task is gone' do
    client, = client_for(exec_chunks(stderr: 'curl: (22) 404', exit_code: 22))
    @client = client

    expect(client.get_task('demo', 'run-1')).to be_nil
  end

  it 'rejects expire values beyond the one hour limit before doing I/O' do
    client, transport = client_for
    @client = client

    expect { client.upsert_task('demo', name: 'run-1', expire: '2h') }.to raise_error(ArgumentError)
    expect { client.upsert_task('demo', name: 'run-1', expire: 3601) }.to raise_error(ArgumentError)
    expect { client.upsert_task('demo', name: 'run-1', expire: 'later') }.to raise_error(ArgumentError)
    expect(transport.requests).to be_empty
  end

  it 'exposes sprite-level convenience methods' do
    client, = client_for
    @client = client
    expect(client.sprite('demo')).to respond_to(:tasks, :task, :hold, :release)
  end
end
