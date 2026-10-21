ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe Instagram::AmhExecutor do
  let(:target) { '90001' }
  let(:reserved) { 'c683ea27-bad5-4c83-9573-e4aca4bcc28a' }
  let(:graph) { JSON.parse(File.read(Rails.root.join('spec/fixtures/amh_visual_graph.json'))) }
  let(:proof) do
    graph['nodes'].find { |n| n['id'] == 'scope' }['data'] = { 'account' => target, 'media' => '90004' }
    graph['nodes'].find { |n| n['id'] == 'reply' }['data'] = { 'confirmationRequired' => true, 'openingText' => 'Posso enviar o material?', 'text' => 'Seu material está pronto.', 'buttonLabel' => 'Acessar material' }
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
              INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID INSTAGRAM_AMH_RESERVED_INBOX_ID INSTAGRAM_AMH_INBOX_IDS INSTAGRAM_AMH_APP_ID INSTAGRAM_AMH_LIKES_ENABLED
              INSTAGRAM_AMH_LIKES_FACEBOOK_USER_TOKEN INSTAGRAM_AMH_LIKES_FACEBOOK_PAGE_ID INSTAGRAM_AMH_LIKES_FACEBOOK_IG_USER_ID]
    previous = ENV.to_h.slice(*keys)
    ENV.update('INSTAGRAM_AMH_EXECUTION_ENABLED' => 'true', 'INSTAGRAM_AMH_LINK_QA_ENABLED' => 'true',
      'INSTAGRAM_AMH_TEST_IGSIDS' => '90002', 'INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID' => target,
      'INSTAGRAM_AMH_RESERVED_INBOX_ID' => reserved, 'INSTAGRAM_AMH_INBOX_IDS' => reserved, 'INSTAGRAM_AMH_APP_ID' => '90003')
    ENV['INSTAGRAM_AMH_LIKES_ENABLED'] = 'false'
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
  def confirm(row, identity: contract['identity'], token: nil, source: 'quick_reply')
    click = { 'kind' => 'dm', 'identity' => identity, 'event_id' => SecureRandom.uuid,
              'occurred_at' => Time.current.iso8601(6), 'confirmation_source' => source,
              'amh_confirmation' => token || Instagram::AmhConfirmationToken.issue(row) }
    Instagram::AmhInboundEvent.create!(inbox_id: reserved, event_key: SecureRandom.hex(32),
      encrypted_contract: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(click))
  end

  it 'sends only an invitation before the click, then delivers one URL button to the same identity' do
    bodies = []
    request = stub_request(:post, "https://graph.instagram.com/v23.0/#{target}/messages").with { |req| bodies << JSON.parse(req.body); true }
      .to_return(status: 200, body: JSON.generate(message_id: 'qa-message'), headers: { 'Content-Type' => 'application/json' })
    first = call
    expect(first.state).to eq('awaiting_confirmation')
    expect(first.prompt_state).to eq('accepted')
    expect(first.encrypted_prompt_receipt).not_to include('qa-message')
    expect(Instagram::AmhShortLink.count).to eq(0)
    expect(bodies.first.dig('recipient', 'comment_id')).to eq(contract['event_id'])
    expect(bodies.first.dig('message', 'quick_replies', 0, 'title')).to eq('Pode enviar')
    expect(bodies.first.to_s).not_to include('https://co.agenciavetorial.com')
    expect(call.id).to eq(first.id)
    expect(request).to have_been_requested.once
    click = confirm(first)
    accepted = Instagram::AmhConfirmation.call(event: click)
    expect(accepted.state).to eq('accepted')
    expect(accepted.confirmation_event_id).to eq(click.id)
    expect(Instagram::AmhShortLink.count).to eq(1)
    final = bodies.last
    expect(final.dig('recipient', 'id')).to eq('90002')
    expect(final.dig('message', 'attachment', 'payload', 'text')).not_to include('https://')
    expect(final.dig('message', 'attachment', 'payload', 'buttons', 0, 'type')).to eq('web_url')
    expect(Instagram::AmhConfirmation.call(event: click).id).to eq(first.id)
    expect(request).to have_been_requested.twice
  end

  it 'rejects a typed confirmation, other identity, forged token, expiry and pause without issuing any link' do
    stub_request(:post, /graph.instagram.com/).to_return(status: 200, body: JSON.generate(message_id: 'qa-prompt'), headers: { 'Content-Type' => 'application/json' })
    row = call
    [confirm(row, identity: contract['identity'].merge('igsid' => '90099')), confirm(row, token: 'AMH_CONFIRM_V1:forged'), confirm(row, source: 'typed_text')].each do |click|
      expect { Instagram::AmhConfirmation.call(event: click) }.to raise_error(described_class::Unavailable)
    end
    row.update!(prompt_expires_at: 1.second.ago)
    expect { Instagram::AmhConfirmation.call(event: confirm(row)) }.to raise_error(described_class::Unavailable)
    row.update!(prompt_expires_at: 1.day.from_now)
    proof.update!(audience: 'paused')
    expect { Instagram::AmhConfirmation.call(event: confirm(row)) }.to raise_error(described_class::Unavailable)
    expect(Instagram::AmhShortLink.count).to eq(0)
  end

  it 'never retries a timeout or an abandoned sending reservation' do
    request = stub_request(:post, /graph.instagram.com/).to_timeout
    expect(call.state).to eq('prompt_uncertain')
    expect(call.state).to eq('prompt_uncertain')
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
    row = call
    client.post(path, params: { audience: 'active', version_id: p.active_version_id, lock_version: p.lock_version }, as: :json)
    expect(client.response.status).to eq(422)
    Instagram::AmhConfirmation.call(event: confirm(row))
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
    row = call
    Instagram::AmhConfirmation.call(event: confirm(row))
    payload = Instagram::AmhShortLink.encryptor.decrypt_and_verify(Instagram::AmhShortLink.last.encrypted_payload)
    expect(payload['event']).not_to have_key('text')
  end

  it 'never retries a material delivery with uncertain result, even after a second valid click' do
    request = stub_request(:post, /graph.instagram.com/).to_return(status: 200, body: JSON.generate(message_id: 'qa-prompt'), headers: { 'Content-Type' => 'application/json' }).then.to_timeout
    row = call
    expect(Instagram::AmhConfirmation.call(event: confirm(row)).state).to eq('uncertain')
    expect(Instagram::AmhConfirmation.call(event: confirm(row)).state).to eq('uncertain')
    expect(request).to have_been_requested.twice
    expect(Instagram::AmhShortLink.count).to eq(1)
  end

  context 'independent comment like' do
    let(:like_url) { "https://graph.facebook.com/v26.0/#{target}/likes" }
    before do
      contract['event_id'] = '90006'
      ENV.update('INSTAGRAM_AMH_LIKES_ENABLED' => 'true', 'INSTAGRAM_AMH_LIKES_FACEBOOK_USER_TOKEN' => 'inert-facebook-user',
                 'INSTAGRAM_AMH_LIKES_FACEBOOK_PAGE_ID' => '90007', 'INSTAGRAM_AMH_LIKES_FACEBOOK_IG_USER_ID' => target)
      stub_request(:get, 'https://graph.facebook.com/v26.0/me/permissions').to_return(
        status: 200, body: JSON.generate(data: %w[instagram_basic instagram_manage_engagement].map { |p| {permission: p, status: 'granted'} }),
        headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, 'https://graph.facebook.com/v26.0/90007').with(query: {fields: 'instagram_business_account{id}'}).to_return(
        status: 200, body: JSON.generate(instagram_business_account: {id: target}), headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, /graph.instagram.com/).to_return(status: 200, body: JSON.generate(message_id: 'qa-prompt'),
                                                        headers: { 'Content-Type' => 'application/json' })
    end

    it 'reserves before calling the correct user edge and preserves separate encrypted receipts on replay' do
      request = stub_request(:post, like_url).with(headers: {'Authorization' => 'Bearer inert-facebook-user'}, body: {comment_id: '90006'}.to_json).to_return do
        expect(Instagram::AmhDelivery.last.like_state).to eq('sending')
        { status: 200, body: '{"success":true}', headers: { 'Content-Type' => 'application/json' } }
      end
      row = call
      expect(row.state).to eq('awaiting_confirmation')
      expect(row.like_state).to eq('accepted')
      expect(row.like_accepted_at).to be_present
      expect(row.encrypted_like_receipt).not_to include('success')
      expect(call.id).to eq(row.id)
      expect(request).to have_been_requested.once
      expect(Instagram::AmhConfirmation.call(event: confirm(row)).state).to eq('accepted')
      expect(row.reload.like_state).to eq('accepted')
    end

    it 'does not retry timeout or rejection and never blocks invitation or material' do
      request = stub_request(:post, like_url).to_timeout
      row = call
      expect(row.like_state).to eq('uncertain')
      expect(call.like_state).to eq('uncertain')
      expect(request).to have_been_requested.once
      expect(Instagram::AmhConfirmation.call(event: confirm(row)).state).to eq('accepted')
    end

    it 'records provider refusal separately from the invitation' do
      request = stub_request(:post, like_url).to_return(status: 403, body: '{"error":{"code":200,"message":"private diagnostic"}}', headers: { 'Content-Type' => 'application/json' })
      row = call
      expect(row.like_state).to eq('failed')
      expect(row.like_reason).to eq('provider_403')
      expect(row.state).to eq('awaiting_confirmation')
      expect(call.like_state).to eq('failed')
      expect(request).to have_been_requested.once
      expect(row.snapshot.to_s).not_to include('private diagnostic', 'inert-facebook-user')
    end

    it 'blocks missing permissions without attempting a like' do
      stub_request(:get, 'https://graph.facebook.com/v26.0/me/permissions').to_return(status: 200, body: '{"data":[]}', headers: { 'Content-Type' => 'application/json' })
      row = call
      expect(row.like_reason).to eq('engagement_permission_required')
      expect(row.state).to eq('awaiting_confirmation')
      expect(WebMock).not_to have_requested(:post, like_url)
    end

    it 'blocks a mismatched Facebook account' do
      ENV['INSTAGRAM_AMH_LIKES_FACEBOOK_IG_USER_ID'] = '90099'
      expect(call.like_reason).to eq('facebook_account_mismatch')
      expect(WebMock).not_to have_requested(:post, /graph.facebook.com/)
    end

    it 'blocks an absent Facebook token and does not replay it when credentials later appear' do
      ENV.delete('INSTAGRAM_AMH_LIKES_FACEBOOK_USER_TOKEN')
      expect(call.like_reason).to eq('facebook_connection_required')
      ENV['INSTAGRAM_AMH_LIKES_FACEBOOK_USER_TOKEN'] = 'inert-facebook-user'
      expect(call.like_state).to eq('blocked')
      expect(WebMock).not_to have_requested(:post, like_url)
    end


    it 'keeps the like independent even if the invitation is refused' do
      stub_request(:post, /graph.instagram.com/).to_return(status: 403, body: '{}', headers: { 'Content-Type' => 'application/json' })
      request = stub_request(:post, like_url).to_return(status: 200, body: '{"success":true}', headers: { 'Content-Type' => 'application/json' })
      row = call
      expect(row.state).to eq('prompt_failed')
      expect(row.reload.like_state).to eq('accepted')
      expect(request).to have_been_requested.once
    end

    it 'rechecks pause after permission preflight and before the mutation' do
      stub_request(:get, 'https://graph.facebook.com/v26.0/90007').with(query: {fields: 'instagram_business_account{id}'}).to_return do
        proof.update!(audience: 'paused')
        {status: 200, body: JSON.generate(instagram_business_account: {id: target}), headers: { 'Content-Type' => 'application/json' }}
      end
      row = call
      expect(row.reload.like_reason).to eq('rule_unavailable')
      expect(WebMock).not_to have_requested(:post, like_url)
    end

    it 'reserves the burst budget across deliveries before calling Meta' do
      allow(Instagram::AmhDelivery).to receive(:where).with('like_requested_at > ?', anything).and_return(double(count: 40))
      row = call
      expect(row.reload.like_reason).to eq('like_rate_limited')
      expect(row.state).to eq('awaiting_confirmation')
      expect(WebMock).not_to have_requested(:post, like_url)
    end

    it 'does not attempt a like for an unauthorized test identity' do
      contract['identity']['igsid'] = '90099'
      expect { call }.to raise_error(described_class::Unavailable)
      expect(WebMock).not_to have_requested(:post, like_url)
    end

    it 'never resumes an abandoned sending reservation or historical delivery' do
      row = Instagram::AmhDelivery.create!(inbound_event: event, proof: proof, version_id: proof.active_version_id, state: 'awaiting_confirmation', prompt_state: 'accepted', like_state: 'sending')
      expect(call.like_state).to eq('sending')
      row.update!(like_state: 'not_requested')
      expect(call.like_state).to eq('not_requested')
      expect(WebMock).not_to have_requested(:post, like_url)
    end

    it 'blocks the like when its independent gate is off' do
      ENV['INSTAGRAM_AMH_LIKES_ENABLED'] = 'false'
      expect(call.reload.like_reason).to eq('like_gate_disabled')
      expect(WebMock).not_to have_requested(:post, like_url)
    end
  end

end
