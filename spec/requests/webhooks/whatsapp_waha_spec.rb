require 'rails_helper'

RSpec.describe 'Webhooks::Whatsapp waha', type: :request do
  describe 'POST /webhooks/whatsapp/waha' do
    it 'enqueues Webhooks::WhatsappEventsJob with waha: true' do
      payload = { id: 'evt_123', event: 'message', session: 'default', payload: { from: '5511999999999@c.us', body: 'hi' } }

      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later).with(hash_including(waha: true, 'event' => 'message', 'session' => 'default'))

      post '/webhooks/whatsapp/waha', params: payload

      expect(response).to have_http_status(:ok)
    end
  end
end
