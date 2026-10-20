ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'
require 'webmock/rspec'

RSpec.describe Instagram::AmhIngress do
  let(:secret) { 'qa-app-secret-not-real' }
  let(:target) { '90001' }
  let(:reserved) { 'c683ea27-bad5-4c83-9573-e4aca4bcc28a' }
  let(:now) { Time.current.to_i }
  let(:entry) do
    { 'id' => target, 'time' => now, 'changes' => [
      { 'field' => 'comments', 'value' => { 'id' => 'comment-qa', 'from' => { 'id' => '90002', 'username' => 'qa_fixture' },
                                            'media' => { 'id' => '90004' }, 'text' => 'QA isolated keyword' } }
    ] }
  end

  def body_for(entries = [entry])
    JSON.generate('object' => 'instagram', 'entry' => entries)
  end

  def signature(body)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  def ingest(body = body_for, sig = signature(body))
    described_class.new(raw: body, signature: sig).perform
  end

  around do |example|
    keys = %w[INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID INSTAGRAM_AMH_RESERVED_INBOX_ID INSTAGRAM_AMH_APP_ID
              INSTAGRAM_AMH_INBOX_IDS INSTAGRAM_AMH_RECEPTION_ENABLED INSTAGRAM_AMH_INGRESS_ENABLED]
    previous = ENV.to_h.slice(*keys)
    ENV.update('INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID' => target, 'INSTAGRAM_AMH_RESERVED_INBOX_ID' => reserved,
               'INSTAGRAM_AMH_APP_ID' => '90003', 'INSTAGRAM_AMH_INBOX_IDS' => reserved,
               'INSTAGRAM_AMH_RECEPTION_ENABLED' => 'false', 'INSTAGRAM_AMH_INGRESS_ENABLED' => 'false')
    raise 'Isolated DB required' unless ActiveRecord::Base.connection_db_config.database == 'instagram_amh_safety_test'

    WebMock.disable_net_connect!
    ActiveRecord::Base.transaction do
      connection = ActiveRecord::Base.connection
      unless connection.table_exists?('instagram_amh_inbound_events')
        require Rails.root.join('db/migrate/20261019150000_create_instagram_amh_inbound_events')
        CreateInstagramAmhInboundEvents.new.change
      end
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    keys.each { |key| ENV.delete(key) }
    ENV.update(previous || {})
    WebMock.allow_net_connect!
    ActiveRecord::Base.connection.schema_cache.clear!
  end

  before do
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_ID', '').and_return('90003')
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', '').and_return(secret)
  end

  def bind
    Instagram::AmhConnection.store!({ 'user_id' => target }, { 'access_token' => 'inert-qa', 'expires_in' => 3600 })
  end

  def enable
    bind
    ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] = 'true'
    ENV['INSTAGRAM_AMH_INGRESS_ENABLED'] = 'true'
  end

  it 'atomically binds the reserved inbox without subscription and repeats without duplication' do
    expect(HTTParty).not_to receive(:post)
    channel = bind
    expect(channel.inbox.id).to eq(reserved)
    expect(channel.subscribe).to be true
    expect(bind.id).to eq(channel.id)
    expect(Inbox.where(id: reserved).count).to eq(1)
    expect(Channel::Instagram.where(instagram_id: target).count).to eq(1)
  end

  it 'rejects wrong account and unsafe scope before persisting or accessing Meta' do
    expect(HTTParty).not_to receive(:post)
    expect { Instagram::AmhConnection.store!({ 'user_id' => '99999' }, { 'access_token' => 'inert', 'expires_in' => 3600 }) }
      .to raise_error(Instagram::AmhConnection::ConfigurationError)
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = ''
    expect { bind }.to raise_error(Instagram::AmhConnection::ConfigurationError)
    expect(Inbox.find_by(id: reserved)).to be_nil
  end

  it 'preserves an existing channel bound to a different inbox' do
    channel = Channel::Instagram.create!(instagram_id: target, access_token: 'old-inert', expires_at: 1.day.from_now)
    old_inbox = Inbox.create!(channel: channel, name: 'Other QA binding')
    expect { bind }.to raise_error(Instagram::AmhConnection::ConfigurationError)
    expect(channel.reload[:access_token]).to eq('old-inert')
    expect(channel.inbox.id).to eq(old_inbox.id)
  end

  it 'requires signature over the exact raw bytes before any lookup or persistence' do
    body = body_for
    expect(Instagram::AmhConnection).not_to receive(:bound_inbox!)
    expect(ingest(body, '').status).to eq(403)
    expect(ingest("#{body} ", signature(body)).status).to eq(403)
    expect(Instagram::AmhInboundEvent.count).to eq(0)
  end

  it 'keeps unconfigured and unrelated accounts on the existing receiver' do
    expect(ingest(body_for([{ 'id' => '99999' }]))).to be_nil
    ENV.delete('INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID')
    expect(ingest).to be_nil
  end

  it 'does not ACK paused or missing bindings and never sends' do
    expect(ingest.status).to eq(503)
    bind
    expect(ingest.status).to eq(503)
    expect(Instagram::AmhInboundEvent.count).to eq(0)
    expect(WebMock).not_to have_requested(:post, /graph\./)
  end

  it 'persists encrypted metadata before ACK and deduplicates comments without a CRM effect' do
    enable
    contact_count = Contact.count
    2.times { expect(ingest.status).to eq(200) }
    event = Instagram::AmhInboundEvent.first
    expect([Instagram::AmhInboundEvent.count, event.state]).to eq([1, 'pending'])
    expect(event.encrypted_contract).not_to include('QA isolated keyword', '90002', 'qa_fixture')
    expect(event.contract['identity']['igsid']).to eq('90002')
    expect(event.contract['comment_text']).to eq('QA isolated keyword')
    expect(Contact.count).to eq(contact_count)
    expect(WebMock).not_to have_requested(:post, /graph\./)
  end

  it 'rolls back the whole batch on invalid or unavailable persistence' do
    enable
    broken = Marshal.load(Marshal.dump(entry))
    broken['changes'][0]['value']['from']['id'] = 90_002
    expect(ingest(body_for([entry, broken])).status).to eq(400)
    expect(Instagram::AmhInboundEvent.count).to eq(0)
    allow(Instagram::AmhInboundEvent).to receive(:create_or_find_by!).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect(ingest.status).to eq(503)
  end

  it 'excludes echoes, own comments and technical events, retaining no DM body' do
    enable
    dm = { 'sender' => { 'id' => '90002' }, 'recipient' => { 'id' => target }, 'timestamp' => now * 1000,
           'message' => { 'mid' => 'qa-mid', 'text' => 'PRIVATE DM MUST NOT BE RETAINED' } }
    e = { 'id' => target, 'time' => now, 'messaging' => [dm] }
    expect(ingest(body_for([e])).status).to eq(200)
    expect(Instagram::AmhInboundEvent.first.contract.to_s).not_to include('PRIVATE DM')
    dm['message']['is_echo'] = true
    e['changes'] = [{ 'field' => 'comments', 'value' => { 'id' => 'own', 'from' => { 'id' => target } } },
                    { 'field' => 'message_reactions', 'value' => {} }]
    expect(ingest(body_for([e])).status).to eq(200)
    expect(Instagram::AmhInboundEvent.count).to eq(1)
  end

  it 'removes only handled entries from mixed batches' do
    enable
    unrelated = { 'id' => '99999', 'messaging' => [] }
    expect(ingest(body_for([entry, unrelated])).remaining).to eq([unrelated])
  end

  it 'handles signed HTTP requests before legacy jobs and refuses forged requests' do
    enable
    expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post('/webhooks/instagram', params: body_for,
                                        headers: { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => signature(body_for) })
    expect(session.response.status).to eq(200)
    expect(Instagram::AmhInboundEvent.count).to eq(1)
    session.post('/webhooks/instagram', params: body_for, headers: { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => 'forged' })
    expect(session.response.status).to eq(403)
    expect(Instagram::AmhInboundEvent.count).to eq(1)
  end

  it 'binds the real OAuth controller path to the reserved inbox without subscribing' do
    expect(HTTParty).not_to receive(:post)
    controller = Api::V1::Instagram::AuthorizationsController.new
    channel = controller.send(:find_or_create_channel, { 'user_id' => target }, { 'access_token' => 'inert-qa', 'expires_in' => 3600 })
    expect(channel.inbox.id).to eq(reserved)
    expect(channel.subscribe).to be true
  end

  it 'clears stale Hub lifecycle metadata after successful direct AMH OAuth' do
    channel = bind
    channel.update!(evolution_hub_meta: { 'status' => 'inactive' })
    reconnected = bind
    expect(reconnected.evolution_hub_meta).to eq({})
    allow(reconnected).to receive(:reauthorization_required?).and_return(false)
    expect(Channels::ConnectionStateResolver.call(reconnected)[:state]).to eq('connected')
  end

  it 'keeps legacy subscriptions for other accounts' do
    allow(MetaBaseUrl).to receive(:enabled?).and_return(false)
    response = instance_double(HTTParty::Response, success?: true)
    expect(HTTParty).to receive(:post).with(%r{99999/subscribed_apps}, anything).and_return(response)
    channel = Channel::Instagram.new(instagram_id: '99999', access_token: 'inert-qa', expires_at: 1.day.from_now)
    expect(channel.subscribe).to be true
  end

  it 'does not create pending identities for explicitly flagged spam' do
    enable
    flagged = Marshal.load(Marshal.dump(entry))
    flagged['changes'][0]['value']['is_spam'] = true
    expect(ingest(body_for([flagged])).status).to eq(200)
    expect(Instagram::AmhInboundEvent.count).to eq(0)
  end

  it 'rolls back already written rows when a later insert fails' do
    enable
    second = Marshal.load(Marshal.dump(entry))
    second['changes'][0]['value']['id'] = 'second-comment'
    attempts = 0
    allow(Instagram::AmhInboundEvent).to receive(:create_or_find_by!).and_wrap_original do |original, *args, &block|
      attempts += 1
      raise ActiveRecord::StatementInvalid, 'isolated failure' if attempts == 2

      original.call(*args, &block)
    end
    expect(ingest(body_for([entry, second])).status).to eq(503)
    expect(Instagram::AmhInboundEvent.count).to eq(0)
  end

  it 'redacts social payloads and OAuth codes from framework request logging' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    data = filter.filter('entry' => [entry], 'code' => 'qa-opaque-code', 'state' => 'qa-opaque-state')
    expect(data.values).to all(eq('[FILTERED]'))
  end

  it 'rejects oversized bodies before JSON parsing' do
    expect(JSON).not_to receive(:parse)
    expect(ingest('x' * (described_class::MAX_BODY + 1)).status).to eq(413)
  end

  it 'accepts millisecond comment timestamps without changing second timestamps' do
    enable
    timestamped = Marshal.load(Marshal.dump(entry))
    timestamped['time'] = now * 1000
    expect(ingest(body_for([timestamped])).status).to eq(200)
    expect(Instagram::AmhInboundEvent.first.contract['occurred_at']).to eq(Time.at(now).utc.iso8601)
  end

  it 'rejects query supplied entries before the legacy queue' do
    expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    query = { 'object' => 'instagram', 'entry' => [entry] }.to_query
    session.post("/webhooks/instagram?#{query}", params: '{}', headers: { 'CONTENT_TYPE' => 'application/json' })
    expect(session.response.status).to eq(400)
    expect(Instagram::AmhInboundEvent.count).to eq(0)
  end

  it 'enforces size, app configuration and signed object type' do
    oversized = Marshal.load(Marshal.dump(entry))
    oversized['changes'][0]['value']['text'] = 'x' * (described_class::MAX_BODY + 1)
    expect(ingest(body_for([oversized])).status).to eq(413)
    oversized['id'] = '99999'
    expect(ingest(body_for([oversized])).status).to eq(413)
    bind
    ENV['INSTAGRAM_AMH_APP_ID'] = 'wrong-app'
    expect(ingest.status).to eq(503)
    body = body_for.sub('instagram', 'page')
    expect(ingest(body).status).to eq(400)
  end
end
