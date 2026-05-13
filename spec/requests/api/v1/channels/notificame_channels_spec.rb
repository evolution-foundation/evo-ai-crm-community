# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::Channels::NotificameChannelsController', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Test User', email: "notificame-test-#{SecureRandom.hex(4)}@example.com") }

  let(:notificame_channels) do
    [
      { 'id' => 'channel-abc', 'phone' => '+5511999999999', 'name' => 'Sales' },
      { 'id' => 'channel-xyz', 'phone' => '+5511888888888', 'name' => 'Support' }
    ]
  end

  let(:valid_params) do
    {
      api_token: 'notif-test-token',
      channel_id: 'channel-abc',
      phone_number: '+5511999999999'
    }
  end

  around do |example|
    original_base_url = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  before do
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true, data: { user: { id: user.id, email: user.email } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    permission_check_url = "#{base_url}/api/v1/users/#{user.id}/check_permission"
    stub_request(:post, permission_check_url)
      .to_return(
        status: 200,
        body: { success: true, data: { has_permission: true } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    Current.user = user
  end

  describe 'POST /api/v1/channels/notificame/verify' do
    context 'with valid params' do
      before do
        allow(Whatsapp::Providers::NotificameService).to receive(:list_channels).and_return(notificame_channels)
      end

      it 'returns 200 and the channels list' do
        post '/api/v1/channels/notificame/verify', params: valid_params, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        parsed = response.parsed_body
        expect(parsed['data']['channels']).to eq(notificame_channels.map(&:stringify_keys))
      end

      it 'does not duplicate the success envelope in the response payload' do
        post '/api/v1/channels/notificame/verify', params: valid_params, headers: headers, as: :json

        parsed = response.parsed_body
        # `success` should appear once at the top of the envelope, not nested under data.
        expect(parsed['data']).not_to have_key('success')
      end
    end

    context 'with mismatched phone number' do
      before do
        allow(Whatsapp::Providers::NotificameService).to receive(:list_channels).and_return(notificame_channels)
      end

      it 'returns 422 with a phone-mismatch error' do
        post '/api/v1/channels/notificame/verify',
             params: valid_params.merge(phone_number: '+5500000000000'),
             headers: headers,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']['message']).to match(/phone number/i)
      end
    end

    context 'with channel_id not in the list' do
      before do
        allow(Whatsapp::Providers::NotificameService).to receive(:list_channels).and_return(notificame_channels)
      end

      it 'returns 422 with channel-not-found error' do
        post '/api/v1/channels/notificame/verify',
             params: valid_params.merge(channel_id: 'channel-missing'),
             headers: headers,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']['message']).to match(/was not found/i)
      end
    end

    context 'when the Notificame token is invalid (empty list)' do
      before do
        allow(Whatsapp::Providers::NotificameService).to receive(:list_channels).and_return([])
      end

      it 'returns 422 asking the operator to verify the token' do
        post '/api/v1/channels/notificame/verify', params: valid_params, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']['message']).to match(/verify the api token/i)
      end
    end

    context 'with missing required params' do
      it 'returns 400 listing the missing fields' do
        post '/api/v1/channels/notificame/verify',
             params: { api_token: 'something' },
             headers: headers,
             as: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body['error']['message']).to include('channel_id', 'phone_number')
      end
    end

    context 'when the Notificame service raises' do
      before do
        allow(Whatsapp::Providers::NotificameService)
          .to receive(:list_channels).and_raise(StandardError.new('connect timeout on https://internal.notificame.invalid'))
      end

      it 'returns a generic 422 and does not echo the raw exception message' do
        post '/api/v1/channels/notificame/verify', params: valid_params, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        body = response.parsed_body
        expect(body['error']['message']).to match(/please check the api token/i)
        expect(body['error']['message']).not_to include('internal.notificame.invalid')
      end
    end

    context 'when the API response contains whitespace and case noise in channel ids' do
      let(:noisy_channels) do
        [{ 'id' => '  Channel-ABC  ', 'phone' => '+5511999999999' }]
      end

      before do
        allow(Whatsapp::Providers::NotificameService).to receive(:list_channels).and_return(noisy_channels)
      end

      it 'still matches when API returns whitespace and uppercase' do
        post '/api/v1/channels/notificame/verify', params: valid_params, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
