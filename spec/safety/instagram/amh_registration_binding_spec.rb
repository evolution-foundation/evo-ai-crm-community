ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe Instagram::AmhRegistrationBinding do
  let(:graph) { JSON.parse(File.read(Rails.root.join('spec/fixtures/amh_visual_graph.json'))) }
  let(:secret) { 'qa-only-registration-secret-' * 3 }
  around do |example|
    raise 'Isolated DB required' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'

    keys = %w[INSTAGRAM_AMH_ASSOCIATION_SECRET INSTAGRAM_AMH_ASSOCIATION_QA_ENABLED INSTAGRAM_AMH_LINK_QA_ENABLED INSTAGRAM_AMH_LINK_SERVICE_SECRET
              INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID INSTAGRAM_AMH_APP_ID INSTAGRAM_AMH_INBOX_IDS INSTAGRAM_AMH_RESERVED_INBOX_ID]
    saved = ENV.to_h.slice(*keys)
    ENV['INSTAGRAM_AMH_ASSOCIATION_SECRET'] = secret
    ENV['INSTAGRAM_AMH_ASSOCIATION_QA_ENABLED'] = 'true'
    ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] = 'true'
    ENV['INSTAGRAM_AMH_LINK_SERVICE_SECRET'] = secret
    ENV['INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID'] = '90001'
    ENV['INSTAGRAM_AMH_APP_ID'] = '90005'
    @old_velma = $velma
    @namespace = "qa-registration:#{SecureRandom.hex(8)}"
    $velma = ConnectionPool.new(size: 2, timeout: 1) { Redis::Namespace.new(@namespace, redis: Redis.new(url: 'redis://127.0.0.1:6379/15')) }
    WebMock.disable_net_connect!
    ActiveRecord::Base.transaction { example.run; raise ActiveRecord::Rollback }
  ensure
    keys.each { |key| ENV.delete(key) }
    ENV.update(saved)
    $velma.with { |redis| redis.keys('*').each { |key| redis.del(key) } }
    $velma.shutdown(&:close)
    $velma = @old_velma
    WebMock.allow_net_connect!
  end

  before do
    scope = graph['nodes'][1]['data']
    scope.update('account' => '90001', 'ad' => '90003', 'media' => '90004')
    channel = Channel::Instagram.create!(instagram_id: '90001', access_token: 'qa-inert', expires_at: 1.day.from_now)
    @inbox = Inbox.create!(channel: channel, name: 'QA registration')
    ENV['INSTAGRAM_AMH_RESERVED_INBOX_ID'] = @inbox.id
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = @inbox.id
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_ID', '').and_return('90005')
    expect(Instagram::AmhConnection.bound_inbox!.id).to eq(@inbox.id)
    @contract = { 'identity' => { 'professional_account_id' => '90001', 'app_id' => '90005', 'login_mode' => 'instagram_login', 'igsid' => '90002' },
                  'kind' => 'comment', 'event_id' => 'qa-comment', 'occurred_at' => Time.current.utc.iso8601,
                  'ad_id' => '90003', 'media_id' => '90004', 'comment_text' => 'Quero AMH!', 'username' => 'qa_profile' }
    @event = Instagram::AmhInboundEvent.create!(inbox_id: @inbox.id, event_key: SecureRandom.hex(32),
             encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(@contract))
    proof = Instagram::AmhVisualProof.create!(name: 'QA registration', draft: graph, create_key: SecureRandom.uuid)
    proof.publish_version!(proof.lock_version, 'qa')
    @version = proof.reload.versions.last
    @source = scope.merge('app' => '90005', 'comment' => 'qa-comment', 'text' => 'AMH', 'inbound_event_id' => @event.id)
    @link = Instagram::AmhShortLink.issue_qa!(proof: proof, version_id: @version['id'], event: @source)
    @input = { 'attribution_id' => @link[:id], 'material' => 'amh', 'version_id' => @version['id'],
               'graph_digest' => @version['digest'], 'request_id' => SecureRandom.uuid, 'email_hash' => Digest::SHA256.hexdigest('qa@example.invalid') }
  end

  def binding(input = @input)
    described_class.issue!(input)
  end

  def replace_event(value)
    @event.update!(encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(value))
  end

  it 'binds only durable inbound identity and immutable request/material with deterministic retry and zero outbound' do
    before = Instagram::AmhShortLink.find(@link[:id]).attributes
    assertion = binding
    encoded, signature = assertion.split('.')
    expect(signature).to eq(OpenSSL::HMAC.hexdigest('SHA256', secret, encoded))
    data = JSON.parse(Base64.urlsafe_decode64(encoded))
    expect(data['event']['identity']['igsid']).to eq('90002')
    expect(data['request_id']).to eq(@input['request_id'])
    expect(data['event'].keys).not_to include('comment_text', 'media_id')
    expect(binding).to eq(assertion)
    expect(Instagram::AmhShortLink.find(@link[:id]).attributes).to eq(before)
    expect(WebMock).not_to have_requested(:post, /./)
  end

  it 'rejects request/version/material substitution, expired and revoked links' do
    %w[material version_id graph_digest request_id email_hash].each do |key|
      expect { binding(@input.merge(key => 'wrong')) }.to raise_error(Instagram::AmhShortLink::Unavailable)
    end
    expect { binding(@input.merge('version_id' => SecureRandom.uuid)) }.to raise_error(Instagram::AmhShortLink::Unavailable)
    expect { binding(@input.merge('graph_digest' => 'b' * 64)) }.to raise_error(Instagram::AmhShortLink::Unavailable)
    row = Instagram::AmhShortLink.find(@link[:id])
    row.update!(expires_at: 1.second.ago)
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
    row.update!(expires_at: 1.day.from_now)
    row.revoke!
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
  end

  it 'rejects fabricated text, own accounts, wrong scope and missing authenticated event' do
    replace_event(@contract.merge('comment_text' => 'Unrelated comment'))
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
    replace_event(@contract.merge('identity' => @contract['identity'].merge('igsid' => '90001')))
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
    replace_event(@contract.merge('ad_id' => 'other'))
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
    @event.destroy!
    expect { binding }.to raise_error(ActiveRecord::RecordNotFound)
  end
  it 'authenticates exact body, rejects replay, respects flags and ignores query substitution' do
    client = ActionDispatch::Integration::Session.new(Rails.application)
    body = JSON.generate(@input.merge('rate_key' => 'a' * 64))
    timestamp = Time.current.to_i.to_s
    nonce = SecureRandom.hex(16)
    headers = { 'CONTENT_TYPE' => 'application/json', 'X-Amh-Timestamp' => timestamp, 'X-Amh-Nonce' => nonce,
                'X-Amh-Signature' => OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{nonce}.#{body}") }
    client.post('/internal/instagram-amh/associate?material=other', params: body, headers: headers)
    expect(client.response.status).to eq(200)
    expect(JSON.parse(client.response.body).keys).to eq(['assertion'])
    expect(client.response.headers['Cache-Control']).to include('no-store')
    client.post('/internal/instagram-amh/associate', params: body, headers: headers)
    expect(client.response.status).to eq(401)
    headers['X-Amh-Nonce'] = SecureRandom.hex(16)
    headers['X-Amh-Signature'] = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{headers['X-Amh-Nonce']}.#{body}")
    client.post('/internal/instagram-amh/associate', params: body + ' ', headers: headers)
    expect(client.response.status).to eq(401)
    ENV['INSTAGRAM_AMH_ASSOCIATION_QA_ENABLED'] = 'false'
    client.post('/internal/instagram-amh/associate', params: body, headers: headers)
    expect(client.response.status).to eq(404)
  end

  it 'bounds the body before parameter parsing on the association path' do
    client = ActionDispatch::Integration::Session.new(Rails.application)
    client.post('/internal/instagram-amh/associate', params: 'x' * 1025, headers: { 'CONTENT_TYPE' => 'application/json' })
    expect(client.response.status).to eq(413)
  end

  def association_post(client, input = @input)
    body = JSON.generate(input.merge('rate_key' => SecureRandom.hex(32)))
    timestamp = Time.current.to_i.to_s
    nonce = SecureRandom.hex(16)
    client.post('/internal/instagram-amh/associate', params: body, headers: {
      'CONTENT_TYPE' => 'application/json', 'X-Amh-Timestamp' => timestamp, 'X-Amh-Nonce' => nonce,
      'X-Amh-Signature' => OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{nonce}.#{body}")
    })
  end

  it 'rejects contradictory authenticated ad/media even when omitted from the issuance source' do
    row = Instagram::AmhShortLink.find(@link[:id])
    payload = Instagram::AmhShortLink.encryptor.decrypt_and_verify(row.encrypted_payload)
    payload['event'].delete('ad')
    row.update!(encrypted_payload: Instagram::AmhShortLink.encryptor.encrypt_and_sign(payload))
    replace_event(@contract.merge('ad_id' => '99999'))
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
    replace_event(@contract)
    expect { binding }.not_to raise_error
    payload['event'].delete('media')
    row.update!(encrypted_payload: Instagram::AmhShortLink.encryptor.encrypt_and_sign(payload))
    replace_event(@contract.merge('media_id' => '99999'))
    expect { binding }.to raise_error(Instagram::AmhShortLink::Unavailable)
  end

  it 'returns unavailable for missing/non-string comment text, without a server error' do
    client = ActionDispatch::Integration::Session.new(Rails.application)
    [nil, 123, {}].each do |text|
      replace_event(@contract.merge('comment_text' => text))
      association_post(client)
      expect(client.response.status).to eq(404)
    end
  end

  it 'enforces a server-owned service budget even when the client rotates rate keys' do
    client = ActionDispatch::Integration::Session.new(Rails.application)
    30.times do
      association_post(client)
      expect(client.response.status).to eq(200)
    end
    association_post(client)
    expect(client.response.status).to eq(429)
  end

  it 'returns a private retryable status when database connections or statements fail' do
    client = ActionDispatch::Integration::Session.new(Rails.application)
    [ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionTimeoutError, ActiveRecord::StatementInvalid].each do |error|
      allow(described_class).to receive(:issue!).and_raise(error, 'private database failure')
      association_post(client)
      expect(client.response.status).to eq(503)
      expect(client.response.body).not_to include('private database failure')
      expect(client.response.headers['Cache-Control']).to include('no-store')
    end
  end

  it 'requires real protected-inbox/account/app configuration' do
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = ''
    expect { binding }.to raise_error(Instagram::AmhConnection::ConfigurationError)
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = @inbox.id
    ENV['INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID'] = '99999'
    expect { binding }.to raise_error(Instagram::AmhConnection::ConfigurationError)
    ENV['INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID'] = '90001'
    ENV['INSTAGRAM_AMH_APP_ID'] = '99999'
    expect { binding }.to raise_error(Instagram::AmhConnection::ConfigurationError)
  end

end
