ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe 'AMH visual proof HTTP and persistence' do
  let(:client) { ActionDispatch::Integration::Session.new(Rails.application) }
  let(:graph) { JSON.parse(File.read(Rails.root.join('spec/fixtures/amh_visual_graph.json'))) }
  let(:permissions) { %w[journeys.read journeys.create journeys.update journeys.toggle_active] }

  around do |example|
    raise 'Isolated DB required' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'
    WebMock.disable_net_connect!
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    Current.reset
    WebMock.allow_net_connect!
  end

  before do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = User.new(id: 'cf931b4c-d5ef-4358-8688-4631b284fe8b', name: 'QA', email: 'qa@example.invalid')
      Current.evo_permission_cache = {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) { |_s, _id, permission| permissions.include?(permission) }
  end

  def request(method, path = '', params = {})
    if method == :get
      client.get("/api/v1/instagram_amh_proofs#{path}", headers: { 'Accept' => 'application/json' })
    else
      client.public_send(method, "/api/v1/instagram_amh_proofs#{path}", params: params, as: :json)
    end
    JSON.parse(client.response.body)
  end

  def create
    response = request(:post, '', { name: 'QA AMH', graph: graph })
    expect(client.response.status).to eq(201), response.to_s
    response.fetch('data')
  end

  it 'persists/reopens drafts and immutable versions, traces the exact saved version and deduplicates retries' do
    proof = create
    id = proof.fetch('id')
    reopened = request(:get, "/#{id}").fetch('data')
    expect(reopened['draft']).to eq(graph)
    expect(reopened['state']).to eq('paused')
    expect(reopened['outbound_enabled']).to be false
    versioned = request(:post, "/#{id}/publish", { lock_version: proof['lock_version'] }).fetch('data')
    version = versioned['versions'].last
    expect(version['actor']).to be_present
    changed = graph.deep_dup
    changed['nodes'][2]['data']['keywords'] = ['CONSULTORIO']
    saved = request(:patch, "/#{id}", { graph: changed, lock_version: versioned['lock_version'] }).fetch('data')
    expect(saved['versions'].last['graph']).to eq(graph)
    run = request(:post, "/#{id}/simulate", { version_id: version['id'], fixture: 'timeout' }).fetch('data').fetch('run')
    expect(run['outcome']).to eq('uncertain')
    expect(run['graph_digest']).to eq(version['digest'])
    expect(run['outbound_calls']).to eq(0)
    retried = request(:post, "/#{id}/simulate", { version_id: version['id'], fixture: 'timeout' }).fetch('data')
    expect(retried['run']['id']).to eq(run['id'])
    expect(retried['proof']['ledger'].size).to eq(1)
    expect(WebMock).not_to have_requested(:post, /graph\.(instagram|facebook)\.com/)
  end

  it 'rejects stale saves/publications, corrupt graphs and unapproved scenarios' do
    proof = create
    id = proof['id']
    request(:post, "/#{id}/publish", { lock_version: proof['lock_version'] })
    request(:patch, "/#{id}", { graph: graph, lock_version: proof['lock_version'] })
    expect(client.response.status).to eq(409)
    request(:post, "/#{id}/publish", { lock_version: proof['lock_version'] })
    expect(client.response.status).to eq(409)
    broken = graph.deep_dup
    broken['edges'].clear
    request(:patch, "/#{id}", { graph: broken, lock_version: 1 })
    expect(client.response.status).to eq(422)
    request(:post, "/#{id}/simulate", { version_id: 'not-a-version', fixture: 'eligible' })
    expect(client.response.status).to eq(422)
  end

  context 'read-only user' do
    let(:permissions) { %w[journeys.read] }
    it 'denies draft creation, editing and publication on the server' do
      proof = Instagram::AmhVisualProof.create!(name: 'QA', draft: graph)
      request(:post, '', { name: 'Denied', graph: graph })
      expect(client.response.status).to eq(403)
      request(:patch, "/#{proof.id}", { graph: graph, lock_version: 0 })
      expect(client.response.status).to eq(403)
      request(:post, "/#{proof.id}/publish", { lock_version: 0 })
      expect(client.response.status).to eq(403)
      expect(proof.reload.versions).to eq([])
      request(:get, "/#{proof.id}")
      expect(client.response.status).to eq(200)
    end
  end

  context 'user without read permission' do
    let(:permissions) { [] }
    it 'denies listing, reading and simulating' do
      proof = Instagram::AmhVisualProof.create!(name: 'QA', draft: graph)
      request(:get)
      expect(client.response.status).to eq(403)
      request(:get, "/#{proof.id}")
      expect(client.response.status).to eq(403)
      request(:post, "/#{proof.id}/simulate", { fixture: 'eligible' })
      expect(client.response.status).to eq(403)
    end
  end
end
