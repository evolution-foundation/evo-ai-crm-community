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
    response = request(:post, '', { name: 'QA AMH', graph: graph, create_key: SecureRandom.uuid })
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
    frozen = request(:post, "/#{id}/simulate", { version_id: version['id'], fixture: 'eligible', text: 'Quero AMH!' }).fetch('data').fetch('run')
    expect(frozen['outcome']).to eq('simulated_accepted')
    expect(frozen['trace'].find { |t| t['node'] == 'keyword' }['status']).to eq('passed')
    expect(Instagram::AmhVisualEngine.simulate(changed, fixture: 'eligible', text: 'Quero AMH!')[:outcome]).to eq('rejected')
    expect(Instagram::AmhVisualProof.find(id).lock_version).to eq(saved['lock_version'])
    run = request(:post, "/#{id}/simulate", { version_id: version['id'], fixture: 'timeout' }).fetch('data').fetch('run')
    expect(run['outcome']).to eq('uncertain')
    expect(run['graph_digest']).to eq(version['digest'])
    expect(run['outbound_calls']).to eq(0)
    retried = request(:post, "/#{id}/simulate", { version_id: version['id'], fixture: 'timeout' }).fetch('data')
    expect(retried['run']['id']).to eq(run['id'])
    expect(retried['proof']['ledger'].size).to eq(2)
    expect(run).not_to have_key('input_digest')
    explicit = request(:post, "/#{id}/simulate", { version_id: version['id'], fixture: 'timeout', text: 'AMH' }).fetch('data')
    expect(explicit['run']['id']).to eq(run['id'])
    request(:patch, "/#{id}", { graph: changed, lock_version: saved['lock_version'] })
    expect(client.response.status).to eq(200)
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

  it 'deduplicates create retries by request key' do
    key = SecureRandom.uuid
    first = request(:post, '', { name: 'Retry QA', graph: graph, create_key: key }).fetch('data')
    second = request(:post, '', { name: 'Retry QA', graph: graph, create_key: key }).fetch('data')
    expect(second['id']).to eq(first['id'])
    expect(Instagram::AmhVisualProof.where(create_key: key).count).to eq(1)
  end

  it 'rejects malformed node settings without a server error' do
    [nil, [], 'invalid'].each do |invalid|
      bad = graph.deep_dup
      bad['nodes'][2]['data'] = invalid
      request(:post, '', { name: 'Bad QA', graph: bad, create_key: SecureRandom.uuid })
      expect(client.response.status).to eq(422)
    end
  end

  it 'records the authenticated service principal on publication' do
    proof = Instagram::AmhVisualProof.create!(name: 'Service QA', draft: graph, create_key: SecureRandom.uuid)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = nil
      Current.service_authenticated = true
    end
    result = request(:post, "/#{proof.id}/publish", { lock_version: proof.lock_version }).fetch('data')
    expect(result['versions'].last['actor']).to eq('service:EVOAI_CRM_API_TOKEN')
  end

  it 'projects the published mapping, preserves the draft and reads only the bound inbox without decrypting PII' do
    channel = Channel::Instagram.create!(instagram_id: 'qa-ops', access_token: 'fixture-inert', expires_at: 1.day.from_now)
    inbox = Inbox.create!(name: 'QA ops', channel: channel)
    allow(Instagram::AmhConnection).to receive(:bound_inbox!).and_return(inbox)
    proof = create
    id = proof['id']
    request(:post, "/#{id}/publish", { lock_version: proof['lock_version'] })
    saved = Instagram::AmhVisualProof.find(id)
    draft = graph.deep_dup
    draft['nodes'].find { |node| node['id'] == 'material' }['data']['material'] = 'amh-consultorio'
    saved.update!(draft: draft)
    2.times do |i|
      Instagram::AmhInboundEvent.create!(inbox_id: inbox.id, event_key: "qa-ops-#{i}", encrypted_contract: 'DO-NOT-DECRYPT', state: 'pending')
    end
    other = Inbox.create!(name: 'QA other', channel: Channel::Instagram.create!(instagram_id: 'other-ops', access_token: 'inert', expires_at: 1.day.from_now))
    Instagram::AmhInboundEvent.create!(inbox_id: other.id, event_key: 'qa-other', encrypted_contract: 'SECRET', state: 'failed')
    result = request(:get, '/operations').fetch('data')
    expect(client.response.status).to eq(200)
    expect(client.response.headers['Cache-Control']).to eq('no-store')
    expect(result.dig('inbound', 'counts')).to eq('pending' => 2)
    expect(result.dig('inbound', 'recent').size).to eq(2)
    expect(result.dig('inbound', 'recent').first.keys).to contain_exactly('id', 'state', 'created_at', 'updated_at')
    rule = result['rules'].find { |row| row['id'] == id }
    expect(rule['material']).to eq('amh')
    expect(rule['draft_changed']).to be true
    expect(rule['version']).to eq(1)
    expect(result['outbound_enabled']).to be false
    expect(result['mautic']).to eq('not_queried')
    %w[SECRET DO-NOT-DECRYPT event_key encrypted_contract].each do |marker|
      expect(client.response.body).not_to include(marker)
    end
    expect(saved.reload.draft).to eq(draft)
    expect(WebMock).not_to have_requested(:any, /graph\.(instagram|facebook)\.com/)
  end

  it 'bounds counts to the same latest receipts and avoids materializing proof histories' do
    channel = Channel::Instagram.create!(instagram_id: 'qa-bounded', access_token: 'inert', expires_at: 1.day.from_now)
    inbox = Inbox.create!(name: 'QA bounded', channel: channel)
    allow(Instagram::AmhConnection).to receive(:bound_inbox!).and_return(inbox)
    55.times do |i|
      Instagram::AmhInboundEvent.create!(inbox_id: inbox.id, event_key: "qa-bounded-#{i}", encrypted_contract: 'not-read',
                                         state: i < 5 ? 'old' : 'pending', created_at: Time.current + i.seconds)
    end
    proof = Instagram::AmhVisualProof.create!(name: 'QA summary', draft: graph, create_key: SecureRandom.uuid)
    proof.publish_version!(0, 'QA')
    proof.simulate_version!(proof.versions.last['id'], 'timeout', 'AMH')
    allow_any_instance_of(Instagram::AmhVisualProof).to receive(:ledger).and_raise('Full ledger must not be read')
    allow_any_instance_of(Instagram::AmhVisualProof).to receive(:versions).and_raise('Full versions must not be read')
    response = request(:get, '/operations').fetch('data')
    expect(response.dig('inbound', 'recent').size).to eq(50)
    expect(response.dig('inbound', 'counts')).to eq('pending' => 50)
    expect(response.dig('inbound', 'counts_scope')).to eq('recent_receipts')
    summary = response['rules'].find { |row| row['id'] == proof.id }
    expect(summary['simulations']).to eq(1)
    expect(summary.dig('last_simulation', 'outcome')).to eq('uncertain')
    expect(summary['version']).to eq(1)
  end

  it 'reports missing account configuration as unavailable rather than an empty healthy queue' do
    allow(Instagram::AmhConnection).to receive(:bound_inbox!).and_raise(Instagram::AmhConnection::ConfigurationError)
    data = request(:get, '/operations').fetch('data')
    expect(client.response.status).to eq(200)
    expect(data.dig('inbound', 'available')).to be false
    expect(data['reception_enabled']).to be false
    expect(data['outbound_enabled']).to be false
  end

  context 'read-only user' do
    let(:permissions) { %w[journeys.read] }
    it 'denies draft creation, editing and publication on the server' do
      proof = Instagram::AmhVisualProof.create!(name: 'QA', draft: graph, create_key: SecureRandom.uuid)
      request(:post, '', { name: 'Denied', graph: graph })
      expect(client.response.status).to eq(403)
      request(:patch, "/#{proof.id}", { graph: graph, lock_version: 0 })
      expect(client.response.status).to eq(403)
      request(:post, "/#{proof.id}/publish", { lock_version: 0 })
      expect(client.response.status).to eq(403)
      request(:post, "/#{proof.id}/simulate", { version_id: 'any', fixture: 'eligible' })
      expect(client.response.status).to eq(403)
      expect(proof.reload.versions).to eq([])
      request(:get, "/#{proof.id}")
      expect(client.response.status).to eq(200)
    end
  end

  context 'user without read permission' do
    let(:permissions) { [] }
    it 'denies listing, reading and simulating' do
      proof = Instagram::AmhVisualProof.create!(name: 'QA', draft: graph, create_key: SecureRandom.uuid)
      request(:get)
      expect(client.response.status).to eq(403)
      request(:get, '/operations')
      expect(client.response.status).to eq(403)
      request(:get, "/#{proof.id}")
      expect(client.response.status).to eq(403)
      request(:post, "/#{proof.id}/simulate", { fixture: 'eligible' })
      expect(client.response.status).to eq(403)
    end
  end
end
