# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Waha::AuthorizationsController, type: :controller do
  let(:user) { User.create!(email: "waha-auth-spec-#{SecureRandom.hex(4)}@example.com", name: 'Spec User') }

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    allow(controller).to receive(:authenticate_request!).and_return(true)
  end

  after { Current.reset }

  describe 'POST #create' do
    it 'creates a channel with provider waha and the given config' do
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200, body: '{}', parsed_response: {})
      )
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200, body: '{}', parsed_response: {})
      )

      post :create, params: {
        authorization: {
          base_url: 'https://waha.example.com',
          api_key: 'key',
          session_name: 'default',
          phone_number: '+5511999999999'
        }
      }

      expect(response).to have_http_status(:success)
      expect(Channel::Whatsapp.find_by(phone_number: '+5511999999999').provider).to eq('waha')
    end

    it 'returns bad_request when required params are missing' do
      post :create, params: { authorization: { base_url: '', api_key: '', session_name: '', phone_number: '' } }

      expect(response).to have_http_status(:bad_request)
    end

    it 'returns unprocessable_entity when the WAHA session creation call fails' do
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: false, code: 500, body: 'boom')
      )

      post :create, params: {
        authorization: {
          base_url: 'https://waha.example.com',
          api_key: 'key',
          session_name: 'default',
          phone_number: '+5511988887777'
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Channel::Whatsapp.find_by(phone_number: '+5511988887777')).to be_nil
    end
  end

  describe 'DELETE #logout' do
    let(:channel) do
      Channel::Whatsapp.create!(
        provider: 'waha',
        phone_number: '+5511977776666',
        provider_config: { 'base_url' => 'https://waha.example.com', 'api_key' => 'key', 'session_name' => 'default',
                            'evolution_hub' => { 'status' => 'active' } }
      )
    end
    let!(:inbox) { Inbox.create!(name: "WAHA Logout Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }

    it 'delegates to WahaService#disconnect_channel_provider' do
      expect_any_instance_of(Whatsapp::Providers::WahaService).to receive(:disconnect_channel_provider)

      delete :logout, params: { id: inbox.id }

      expect(response).to have_http_status(:success)
    end
  end
end
