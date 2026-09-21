# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /api/v1/conversations/:id/messages (pagination)', type: :request do
  let(:inbox) { Inbox.create!(name: 'Pagination Inbox', channel: Channel::Api.create!) }
  let(:contact) { Contact.create!(name: 'Pager', email: "pager-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  let!(:messages) do
    Array.new(25) do |i|
      Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming,
                      content: "msg #{i}", created_at: Time.zone.at(1_760_000_000))
    end
  end

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def list(params)
    get "/api/v1/conversations/#{conversation.id}/messages", params: params, headers: headers
  end

  def ids
    response.parsed_body['data'].map { |m| m['id'] }
  end

  it 'honors page' do
    list(page: 1)
    first_page = ids
    list(page: 2)

    expect(response).to have_http_status(:ok)
    expect(ids.size).to eq(5)
    expect(first_page + ids).to match_array(messages.map(&:id))
  end

  it 'rejects page combined with a cursor' do
    list(page: 2, before: messages.last.id)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig('error', 'code')).to eq('INVALID_PARAMETER')
  end

  it 'answers 422 for a page whose offset would overflow, not 500' do
    list(page: MessageFinder::MAX_PAGE + 1)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig('error', 'code')).to eq('INVALID_PARAMETER')
  end
end
