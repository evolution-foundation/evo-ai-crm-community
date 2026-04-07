# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/v1/inboxes/:id', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) do
    {
      'X-Service-Token' => service_token
    }
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'hmac_mandatory serialization' do
    context 'when inbox is API channel' do
      let(:api_channel) { Channel::Api.create!(hmac_mandatory: true) }
      let(:inbox) { Inbox.create!(channel: api_channel, name: 'API Inbox') }

      it 'includes hmac_mandatory in response' do
        get "/api/v1/inboxes/#{inbox.id}", headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response['success']).to be(true)
        expect(json_response['data']).to have_key('hmac_mandatory')
        expect(json_response['data']['hmac_mandatory']).to be(true)
      end
    end

    context 'when inbox is WebWidget channel' do
      let(:web_widget_channel) { Channel::WebWidget.create!(hmac_mandatory: true, website_url: 'https://widget.example.com') }
      let(:inbox) { Inbox.create!(channel: web_widget_channel, name: 'WebWidget Inbox') }

      it 'includes hmac_mandatory in response' do
        get "/api/v1/inboxes/#{inbox.id}", headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response['success']).to be(true)
        expect(json_response['data']).to have_key('hmac_mandatory')
        expect(json_response['data']['hmac_mandatory']).to be(true)
      end
    end

    context 'when inbox is WhatsApp channel' do
      let(:whatsapp_channel) do
        c = Channel::Whatsapp.new(provider: 'evolution', phone_number: "+1555#{SecureRandom.hex(3)}")
        c.save!(validate: false)
        c
      end
      let(:inbox) { Inbox.create!(channel: whatsapp_channel, name: 'WhatsApp Inbox') }

      it 'does NOT include hmac_mandatory in response' do
        get "/api/v1/inboxes/#{inbox.id}", headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response['success']).to be(true)
        expect(json_response['data']).not_to have_key('hmac_mandatory')
      end
    end

    context 'when inbox is Email channel' do
      let(:email_channel) { Channel::Email.create!(email: "email-#{SecureRandom.hex(4)}@example.com", forward_to_email: 'forward@example.com') }
      let(:inbox) { Inbox.create!(channel: email_channel, name: 'Email Inbox') }

      it 'does NOT include hmac_mandatory in response' do
        get "/api/v1/inboxes/#{inbox.id}", headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response['success']).to be(true)
        expect(json_response['data']).not_to have_key('hmac_mandatory')
      end
    end
  end
end
