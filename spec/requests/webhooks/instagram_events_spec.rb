# frozen_string_literal: true

require 'rails_helper'

# POST /webhooks/instagram is called by Meta with an HMAC of the raw body in
# X-Hub-Signature-256. Without the check anyone could hand the job a forged
# entry, and the DM path resolves the inbox from an id that is not a secret.
RSpec.describe 'Webhooks Instagram events', type: :request do
  let(:path) { '/webhooks/instagram' }
  let(:instagram_secret) { 'instagram-app-secret' }
  let(:facebook_secret) { 'facebook-app-secret' }
  let(:entry) do
    { 'id' => '17841400000000000', 'time' => 1_756_242_000,
      'messaging' => [{ 'sender' => { 'id' => '17841400000000001' }, 'recipient' => { 'id' => '17841400000000000' },
                        'timestamp' => 1_756_242_000, 'message' => { 'mid' => 'mid.1', 'text' => 'oi' } }] }
  end
  let(:payload) { { 'object' => 'instagram', 'entry' => [entry] } }
  let(:raw_body) { payload.to_json }

  def sign(body, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, body)}"
  end

  def post_events(body: raw_body, signature: nil)
    headers = { 'Content-Type' => 'application/json' }
    headers['X-Hub-Signature-256'] = signature if signature
    post path, params: body, headers: headers
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return(instagram_secret)
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', nil).and_return(facebook_secret)
  end

  shared_examples 'refuses without enqueueing' do
    it 'answers 401 and never reaches the job' do
      expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)

      subject_request

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'signature' do
    it 'accepts a body signed with the Instagram app secret' do
      expect(Webhooks::InstagramEventsJob).to receive(:perform_later).with([entry])

      post_events(signature: sign(raw_body, instagram_secret))

      expect(response).to have_http_status(:ok)
    end

    it 'accepts a body signed with the Facebook app secret (Instagram through a page)' do
      expect(Webhooks::InstagramEventsJob).to receive(:perform_later).with([entry])

      post_events(signature: sign(raw_body, facebook_secret))

      expect(response).to have_http_status(:ok)
    end

    context 'without the header' do
      let(:subject_request) { post_events }

      it_behaves_like 'refuses without enqueueing'
    end

    context 'with a header that is not sha256=<hex>' do
      let(:subject_request) { post_events(signature: OpenSSL::HMAC.hexdigest('sha256', instagram_secret, raw_body)) }

      it_behaves_like 'refuses without enqueueing'
    end

    context 'with a signature made with another secret' do
      let(:subject_request) { post_events(signature: sign(raw_body, 'not-the-app-secret')) }

      it_behaves_like 'refuses without enqueueing'
    end

    context 'with a sha1= header that carries a valid sha256 digest' do
      let(:subject_request) { post_events(signature: sign(raw_body, instagram_secret).sub('sha256=', 'sha1=')) }

      it_behaves_like 'refuses without enqueueing'
    end

    context 'when the body was changed after signing' do
      let(:subject_request) { post_events(body: raw_body.sub('oi', 'tchau'), signature: sign(raw_body, instagram_secret)) }

      it_behaves_like 'refuses without enqueueing'
    end

    context 'when neither app secret is configured' do
      let(:instagram_secret) { nil }
      let(:facebook_secret) { nil }
      let(:subject_request) { post_events(signature: sign(raw_body, 'anything')) }

      it_behaves_like 'refuses without enqueueing'
    end

    context 'when the configured secrets are blank' do
      let(:instagram_secret) { '' }
      let(:facebook_secret) { '' }
      # An HMAC made with an empty key is computable by anyone; a blank config must not match it.
      let(:subject_request) { post_events(signature: sign(raw_body, '')) }

      it_behaves_like 'refuses without enqueueing'
    end

    it 'gives the same answer whatever the reason, so the response tells nothing about the config' do
      post_events
      missing = response.body
      post_events(signature: sign(raw_body, 'wrong'))

      expect(response.body).to eq(missing)
    end

    it 'leaves the GET handshake without a signature' do
      allow(GlobalConfigService).to receive(:load).with('IG_VERIFY_TOKEN', '').and_return('verify-me')
      allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_VERIFY_TOKEN', '').and_return('')

      get path, params: { 'hub.mode' => 'subscribe', 'hub.verify_token' => 'verify-me', 'hub.challenge' => '42' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq('42')
    end
  end

  describe 'envelope' do
    def post_signed(body)
      post_events(body: body, signature: sign(body, instagram_secret))
    end

    it 'answers 422 when object is missing, instead of a 500' do
      expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)

      post_signed({ 'entry' => [entry] }.to_json)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'answers 422 when the object is not instagram' do
      expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)

      post_signed({ 'object' => 'page', 'entry' => [entry] }.to_json)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    [
      ['entry is missing', nil],
      ['entry is an object', { 'id' => '1' }],
      ['entry is a string', 'oops'],
      ['entry is an array of strings', %w[a b]]
    ].each do |label, value|
      it "answers 422 without enqueueing when #{label}" do
        expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)
        body = { 'object' => 'instagram', 'entry' => value }.compact.to_json

        post_signed(body)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe 'events inside an entry' do
    let(:base_entry) { { 'id' => '17841400000000000', 'time' => 1 } }

    [
      ['messaging is a string', { 'messaging' => 'oops' }],
      ['messaging is an array of strings', { 'messaging' => %w[a b] }],
      ['messaging is an object', { 'messaging' => { 'sender' => { 'id' => '1' } } }],
      ['standby is a string', { 'standby' => 'oops' }]
    ].each do |label, extra|
      it "answers 422 without enqueueing when #{label}" do
        expect(Webhooks::InstagramEventsJob).not_to receive(:perform_later)
        body = { 'object' => 'instagram', 'entry' => [base_entry.merge(extra)] }.to_json

        post_events(body: body, signature: sign(body, instagram_secret))

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it 'still enqueues a well formed DM and a changes-only entry' do
      expect(Webhooks::InstagramEventsJob).to receive(:perform_later).with([entry, { 'id' => '1', 'changes' => [] }])
      body = { 'object' => 'instagram', 'entry' => [entry, { 'id' => '1', 'changes' => [] }] }.to_json

      post_events(body: body, signature: sign(body, instagram_secret))

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'Rack::Attack throttle' do
    around do |example|
      original_enabled = Rack::Attack.enabled
      original_store = Rack::Attack.cache.store
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      Rack::Attack.reset!
      example.run
      Rack::Attack.enabled = original_enabled
      Rack::Attack.cache.store = original_store
      Rack::Attack.reset!
    end

    let(:mock_session) { Rack::MockRequest.new(Rack::Attack.new(->(_env) { [200, {}, ['ok']] })) }

    it 'registers a per-minute ceiling well above what Meta sends' do
      throttle = Rack::Attack.throttles['webhooks/instagram']

      expect(throttle).to be_present
      expect(throttle.limit).to eq(1800)
      expect(throttle.period).to eq(60)
    end

    it 'answers 429 past the ceiling, signature or not' do
      1800.times { mock_session.post(path, 'REMOTE_ADDR' => '203.0.113.7') }

      expect(mock_session.post(path, 'REMOTE_ADDR' => '203.0.113.7').status).to eq(429)
    end

    it 'does not count the GET handshake' do
      1800.times { mock_session.get(path, 'REMOTE_ADDR' => '203.0.113.7') }

      expect(mock_session.post(path, 'REMOTE_ADDR' => '203.0.113.7').status).to eq(200)
    end

    it 'gives another address its own bucket' do
      1800.times { mock_session.post(path, 'REMOTE_ADDR' => '203.0.113.7') }

      expect(mock_session.post(path, 'REMOTE_ADDR' => '203.0.113.8').status).to eq(200)
    end
  end
end
