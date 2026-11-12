# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/conversations/:id/custom_attributes', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://custom-attributes.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:attributes) { { 'origem' => 'darwin', 'prioridade' => 'alta' } }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  it 'saves the attributes when the conversation is addressed by id' do
    post "/api/v1/conversations/#{conversation.id}/custom_attributes",
         params: { custom_attributes: attributes },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.custom_attributes).to eq(attributes)
    expect(response.parsed_body.dig('data', 'custom_attributes')).to eq(attributes)
  end

  it 'saves the attributes when the conversation is addressed by display_id' do
    post "/api/v1/conversations/#{conversation.display_id}/custom_attributes",
         params: { custom_attributes: attributes },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.custom_attributes).to eq(attributes)
  end

  it 'returns not found for an unknown conversation' do
    post "/api/v1/conversations/#{SecureRandom.uuid}/custom_attributes",
         params: { custom_attributes: attributes },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
  end
end
