# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::Search inbox scoping', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:service_token) { 'spec-service-token' }

  let!(:user) { User.create!(name: 'Search User', email: "search-#{SecureRandom.hex(4)}@example.com") }
  let!(:visible_inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Visible Inbox') }
  let!(:hidden_inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Hidden Inbox') }
  let!(:visible_conversation) { conversation_in(visible_inbox) }
  let!(:hidden_conversation) { conversation_in(hidden_inbox) }

  around do |example|
    original_base_url = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    original_service_token = ENV.fetch('EVOAI_CRM_API_TOKEN', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    Rails.cache.clear
    Current.reset
    example.run
  ensure
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
    ENV['EVOAI_CRM_API_TOKEN'] = original_service_token
  end

  def conversation_in(inbox, with_message: true)
    contact = Contact.create!(name: 'Searchable Contact', email: "contact-#{SecureRandom.hex(4)}@example.com")
    contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    return conversation unless with_message

    Message.create!(conversation: conversation, inbox: inbox, message_type: :incoming, content: 'hi', sender: contact)
    conversation
  end

  def stub_auth(role_key:, granted:)
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: role_key, name: role_key } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  def returned_conversation_ids
    response.parsed_body.dig('payload', 'conversations').map { |c| c['id'] }
  end

  describe 'GET /api/v1/search/conversations' do
    it 'searches every inbox for a service-token call' do
      get '/api/v1/search/conversations', params: { q: 'Searchable' },
                                          headers: { 'X-Service-Token' => service_token }

      expect(response).to have_http_status(:ok)
      expect(returned_conversation_ids).to contain_exactly(visible_conversation.id, hidden_conversation.id)
    end

    it 'searches only the assigned inboxes of a restricted user' do
      InboxMember.create!(inbox: visible_inbox, user: user)
      stub_auth(role_key: 'agent_restricted', granted: %w[conversations.read])

      get '/api/v1/search/conversations', params: { q: 'Searchable' },
                                          headers: { 'Authorization' => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(returned_conversation_ids).to contain_exactly(visible_conversation.id)
    end
  end

  describe 'a conversation without messages' do
    let!(:empty_conversation) { conversation_in(visible_inbox, with_message: false) }
    let(:service_headers) { { 'X-Service-Token' => service_token } }

    it 'is listed by GET /api/v1/search/conversations' do
      get '/api/v1/search/conversations', params: { q: 'Searchable' }, headers: service_headers

      expect(response).to have_http_status(:ok)
      expect(returned_conversation_ids).to include(empty_conversation.id)
      empty = response.parsed_body.dig('payload', 'conversations').find { |c| c['id'] == empty_conversation.id }
      expect(empty['message']).to be_blank
    end

    it 'is listed by GET /api/v1/search' do
      get '/api/v1/search', params: { q: 'Searchable' }, headers: service_headers

      expect(response).to have_http_status(:ok)
      expect(returned_conversation_ids).to include(empty_conversation.id)
    end
  end
end
