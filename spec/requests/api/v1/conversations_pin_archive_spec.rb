# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/conversations/:id/pin', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://pin.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact', email: 'spec@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end
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

  it 'pins conversation by setting custom_attributes' do
    post "/api/v1/conversations/#{conversation.id}/pin",
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.custom_attributes['pinned']).to be(true)
    expect(json_response.dig('data', 'custom_attributes', 'pinned')).to be(true)
  end
end

RSpec.describe 'POST /api/v1/conversations/:id/unpin', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://unpin.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact', email: 'spec@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      custom_attributes: { 'pinned' => true }
    )
  end
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

  it 'unpins conversation by updating custom_attributes' do
    post "/api/v1/conversations/#{conversation.id}/unpin",
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.custom_attributes['pinned']).to be(false)
    expect(json_response.dig('data', 'custom_attributes', 'pinned')).to be(false)
  end
end

RSpec.describe 'POST /api/v1/conversations/:id/archive', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://archive.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact', email: 'spec@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end
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

  it 'archives conversation by setting custom_attributes' do
    post "/api/v1/conversations/#{conversation.id}/archive",
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.custom_attributes['archived']).to be(true)
    expect(json_response.dig('data', 'custom_attributes', 'archived')).to be(true)
  end
end

RSpec.describe 'POST /api/v1/conversations/:id/unarchive', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://unarchive.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Spec Contact', email: 'spec@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      custom_attributes: { 'archived' => true }
    )
  end
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

  it 'unarchives conversation by updating custom_attributes' do
    post "/api/v1/conversations/#{conversation.id}/unarchive",
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.custom_attributes['archived']).to be(false)
    expect(json_response.dig('data', 'custom_attributes', 'archived')).to be(false)
  end
end
