ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe Instagram::AmhExecutor do
  let(:target) { '90001' }
  let(:reserved) { 'c683ea27-bad5-4c83-9573-e4aca4bcc28a' }
  let(:graph) { JSON.parse(File.read(Rails.root.join('spec/fixtures/amh_visual_graph.json'))) }
  let(:proof) do
    graph['nodes'].find { |n| n['id'] == 'scope' }['data'] = { 'account' => target, 'media' => '90004' }
    record = Instagram::AmhVisualProof.create!(name: 'QA product', draft: graph, create_key: SecureRandom.uuid)
    record.publish_version!(record.lock_version, 'qa')
    record.reload.update!(active_version_id: record.versions.last['id'], audience: 'test', activated_at: 1.hour.ago)
    record
  end
  let(:contract) do
    { 'identity' => { 'professional_account_id' => target, 'app_id' => '90003', 'igsid' => '90002' },
      'kind' => 'comment', 'event_id' => 'qa-comment', 'occurred_at' => 5.minutes.ago.iso8601,
      'time_source' => 'webhook_entry', 'media_id' => '90004', 'comment_text' => 'Quero AMH!' }
  end
  let(:event) do
    Instagram::AmhInboundEvent.create!(inbox_id: reserved, event_key: SecureRandom.hex(32),
      encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(contract))
  end
  around do |example|
    raise 'Isolated DB required' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'
    keys = %w[INSTAGRAM_AMH_EXECUTION_ENABLED INSTAGRAM_AMH_LINK_QA_ENABLED INSTAGRAM_AMH_TEST_IGSIDS
              INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID INSTAGRAM_AMH_RESERVED_INBOX_ID INSTAGRAM_AMH_INBOX_IDS INSTAGRAM_AMH_APP_ID]
    previous = ENV.to_h.slice(*keys)
    ENV.update('INSTAGRAM_AMH_EXECUTION_ENABLED' => 'true', 'INSTAGRAM_AMH_LINK_QA_ENABLED' => 'true',
      'INSTAGRAM_AMH_TEST_IGSIDS' => '90002', 'INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID' => target,
      'INSTAGRAM_AMH_RESERVED_INBOX_ID' => reserved, 'INSTAGRAM_AMH_INBOX_IDS' => reserved, 'INSTAGRAM_AMH_APP_ID' => '90003')
    WebMock.disable_net_connect!
    ActiveRecord::Base.transaction { example.run; raise ActiveRecord::Rollback }
  ensure
    keys.each { |key| ENV[key] = previous[key] }
    WebMock.allow_net_connect!
  end
  before do
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_ID', '').and_return('90003')
    channel = Channel::Instagram.create!(instagram_id: target, access_token: 'inert-qa', expires_at: 1.day.from_now)
    Inbox.create!(id: reserved, channel: channel, name: 'QA')
  end
  def call
    described_class.call(event: event, proof: proof, explicit_test: true)
  end
  it 'sends a comment-scoped private reply once and encrypts the provider receipt' do
    request = stub_request(:post, "https://graph.instagram.com/v23.0/#{target}/messages").with do |req|
      body = JSON.parse(req.body)
      body.dig('recipient', 'comment_id') == contract['event_id'] && body.dig('message', 'text').include?('https://co.agenciavetorial.com/')
    end.to_return(status: 200, body: JSON.generate(message_id: 'qa-message', recipient_id: '90002'), headers: { 'Content-Type' => 'application/json' })
    first = call
    expect(first.state).to eq('accepted')
    expect(first.encrypted_receipt).not_to include('qa-message')
    expect(call.id).to eq(first.id)
    expect(request).to have_been_requested.once
    expect(Instagram::AmhShortLink.count).to eq(1)
  end
  it 'never retries a timeout or an abandoned sending reservation' do
    request = stub_request(:post, /graph.instagram.com/).to_timeout
    expect(call.state).to eq('uncertain')
    expect(call.state).to eq('uncertain')
    expect(request).to have_been_requested.once
  end
  it 'blocks unauthorized recipients, expired comments, live and nonmatching words before issuing a link' do
    proof
    [{ 'identity' => contract['identity'].merge('igsid' => '90099') }, { 'occurred_at' => 8.days.ago.iso8601 },
     { 'live' => true }, { 'comment_text' => 'XAMH' }, { 'media_id' => '90005' }, { 'kind' => 'dm' }].each do |patch|
      event.update!(encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(contract.merge(patch)))
      expect { call }.to raise_error(described_class::Unavailable)
    end
    expect(Instagram::AmhDelivery.count).to eq(0)
    expect(Instagram::AmhShortLink.count).to eq(0)
  end
  it 'blocks ambiguous active rules and paused operational gates' do
    proof
    other = Instagram::AmhVisualProof.create!(name: 'QA conflict', draft: graph, create_key: SecureRandom.uuid)
    other.publish_version!(other.lock_version, 'qa')
    other.reload.update!(active_version_id: other.versions.last['id'], audience: 'test', activated_at: 1.hour.ago)
    expect { call }.to raise_error(described_class::Unavailable)
    other.update!(audience: 'paused')
    ENV['INSTAGRAM_AMH_EXECUTION_ENABLED'] = 'false'
    expect { call }.to raise_error(described_class::Unavailable)
    expect(Instagram::AmhDelivery.count).to eq(0)
  end
  it 'never replays comments from before commercial activation' do
    proof.update!(audience: 'active', activated_at: Time.current)
    expect { described_class.call(event: event, proof: proof) }.to raise_error(described_class::Unavailable)
  end
  it 'requires a successful real receipt before activation, enforces revision and supports pause' do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = User.new(id: 'cf931b4c-d5ef-4358-8688-4631b284fe8b', name: 'QA', email: 'qa@example.invalid')
      Current.evo_permission_cache = {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    client = ActionDispatch::Integration::Session.new(Rails.application)
    p = proof
    path = "/api/v1/instagram_amh_proofs/#{p.id}/activate"
    client.post(path, params: { audience: 'active', version_id: p.active_version_id, lock_version: p.lock_version }, as: :json)
    expect(client.response.status).to eq(422)
    stub_request(:post, /graph.instagram.com/).to_return(status: 200, body: JSON.generate(message_id: 'qa-message'), headers: { 'Content-Type' => 'application/json' })
    call
    client.post(path, params: { audience: 'active', version_id: p.active_version_id, lock_version: p.lock_version }, as: :json)
    expect(client.response.status).to eq(200), client.response.body
    expect(JSON.parse(client.response.body).dig('data', 'state')).to eq('active')
    client.post(path, params: { audience: 'paused', lock_version: p.lock_version }, as: :json)
    expect(client.response.status).to eq(409)
    p.reload
    client.post(path, params: { audience: 'paused', lock_version: p.lock_version }, as: :json)
    expect(client.response.status).to eq(200)
    expect(p.reload.audience).to eq('paused')
    expect { call }.to raise_error(described_class::Unavailable)
  ensure
    Current.reset
  end

  it 'matches keywords beyond the first 200 characters without persisting comment text in links' do
    contract['comment_text'] = ('Texto do comentário. ' * 20) + 'AMH!'
    stub_request(:post, /graph.instagram.com/).to_return(status: 200, body: JSON.generate(message_id: 'qa-long'), headers: { 'Content-Type' => 'application/json' })
    expect(call.state).to eq('accepted')
    payload = Instagram::AmhShortLink.encryptor.decrypt_and_verify(Instagram::AmhShortLink.last.encrypted_payload)
    expect(payload['event']).not_to have_key('text')
  end

end
