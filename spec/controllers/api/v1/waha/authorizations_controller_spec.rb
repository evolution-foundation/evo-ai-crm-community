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
    # Verify-only: this endpoint starts the WAHA session on the remote server
    # and registers the webhook, but the CRM Channel::Whatsapp/Inbox is
    # persisted separately by the frontend's generic InboxesService.createChannel
    # call (same phone_number) — mirroring evolution_go's authorization#create,
    # which only verifies/creates the remote instance. Persisting a channel
    # here too would make that second call fail on the phone_number uniqueness
    # constraint and leave a permanent orphaned Inbox behind.
    it 'starts a WAHA session and returns session status, without creating a Channel::Whatsapp' do
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200, body: '{"status":"STARTING"}',
                                             parsed_response: { 'status' => 'STARTING' })
      )

      expect do
        post :create, params: {
          authorization: {
            base_url: 'https://waha.example.com',
            api_key: 'key',
            session_name: 'default',
            phone_number: '+5511999999999'
          }
        }
      end.not_to change(Channel::Whatsapp, :count)

      expect(response).to have_http_status(:success)
      expect(Channel::Whatsapp.find_by(phone_number: '+5511999999999')).to be_nil
      body = JSON.parse(response.body)
      expect(body['session_name']).to eq('default')
      expect(body['status']).to eq('STARTING')
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
