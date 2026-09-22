require 'rails_helper'

RSpec.describe 'Webhooks::Whatsapp waha', type: :request do
  let(:webhook_hmac_key) { 'a' * 64 }
  let!(:channel) do
    Channel::Whatsapp.create!(
      provider: 'waha',
      phone_number: '+5511999999999',
      provider_config: {
        'base_url' => 'https://waha.example.com',
        'api_key' => 'key',
        'session_name' => 'default',
        'webhook_hmac_key' => webhook_hmac_key,
        'evolution_hub' => { 'status' => 'active' }
      }
    )
  end
  let!(:inbox) { Inbox.create!(name: "WAHA Webhook Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }

  let(:payload) do
    { id: 'evt_123', event: 'message', session: 'default', payload: { from: '5511999999999@c.us', body: 'hi' } }
  end

  def signature_for(body_json, key)
    OpenSSL::HMAC.hexdigest('SHA512', key, body_json)
  end

  describe 'POST /webhooks/whatsapp/waha' do
    it 'accepts and enqueues the job when the HMAC signature is valid' do
      body_json = payload.to_json
      signature = signature_for(body_json, webhook_hmac_key)

      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)
        .with(hash_including(waha: true, 'event' => 'message', 'session' => 'default'))

      post '/webhooks/whatsapp/waha',
           params: body_json,
           headers: { 'Content-Type' => 'application/json', 'X-Webhook-Hmac' => signature }

      expect(response).to have_http_status(:ok)
    end

    it 'rejects the request with 401 when the HMAC signature is missing' do
      expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_later)

      post '/webhooks/whatsapp/waha',
           params: payload.to_json,
           headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects the request with 401 when the HMAC signature is invalid' do
      expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_later)

      post '/webhooks/whatsapp/waha',
           params: payload.to_json,
           headers: { 'Content-Type' => 'application/json', 'X-Webhook-Hmac' => 'not-the-right-signature' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects the request with 401 when no channel matches the session name' do
      body_json = payload.merge(session: 'unknown-session').to_json
      signature = signature_for(body_json, webhook_hmac_key)

      expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_later)

      post '/webhooks/whatsapp/waha',
           params: body_json,
           headers: { 'Content-Type' => 'application/json', 'X-Webhook-Hmac' => signature }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
