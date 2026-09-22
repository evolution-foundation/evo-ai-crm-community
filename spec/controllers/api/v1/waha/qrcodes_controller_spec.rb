# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Waha::QrcodesController, type: :controller do
  let(:user) { User.create!(email: "waha-qr-spec-#{SecureRandom.hex(4)}@example.com", name: 'Spec User') }
  let(:channel) do
    Channel::Whatsapp.create!(
      provider: 'waha',
      phone_number: '+5511966665555',
      provider_config: { 'base_url' => 'https://waha.example.com', 'api_key' => 'key', 'session_name' => 'default',
                          'evolution_hub' => { 'status' => 'active' } }
    )
  end
  let!(:inbox) { Inbox.create!(name: "WAHA QR Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    allow(controller).to receive(:authenticate_request!).and_return(true)
  end

  after { Current.reset }

  describe 'GET #show' do
    it 'returns the base64 QR code from WAHA' do
      response_double = instance_double(HTTParty::Response, success?: true, parsed_response: { 'value' => 'data:image/png;base64,AAA' })
      expect(HTTParty).to receive(:get).with(
        'https://waha.example.com/api/default/auth/qr',
        hash_including(query: { format: 'raw' })
      ).and_return(response_double)

      get :show, params: { id: inbox.id }

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)['qr_data_url']).to eq('data:image/png;base64,AAA')
    end

    it 'returns unprocessable_entity when WAHA responds with a failure' do
      response_double = instance_double(HTTParty::Response, success?: false, code: 500)
      allow(HTTParty).to receive(:get).and_return(response_double)

      get :show, params: { id: inbox.id }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
