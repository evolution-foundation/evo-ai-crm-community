# frozen_string_literal: true

require 'rails_helper'

# CRM-212 follow-up: `POST /api/v1/conversations/:conversation_id/labels`
# REPLACES the full label set. The AI's own manage_conversation_labels tool
# (and anything else that only knows the one label it wants to add/remove,
# e.g. the `atendimento_ia` gate label) previously had to GET the current
# set, merge locally, then POST the full result back — a read-then-replace
# race where a concurrent change landing between the GET and the POST (an
# operator removing `atendimento_ia` mid-turn) gets silently overwritten.
# These atomic /add and /remove endpoints apply directly against whatever is
# persisted at write time, so a single-label caller never needs to read first.
RSpec.describe 'Api::V1::Conversations::Labels', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://labels.example.com') }
  let(:inbox) { Inbox.create!(name: 'Labels Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Labels Contact', email: 'labels@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    allow(Current).to receive(:account).and_return({ 'id' => 1, 'name' => 'Runtime Account' })
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'POST /api/v1/conversations/:conversation_id/labels/add' do
    it 'adds a label without disturbing existing labels' do
      post "/api/v1/conversations/#{conversation.id}/labels",
           params: { labels: ['vip'] }, headers: headers, as: :json

      post "/api/v1/conversations/#{conversation.id}/labels/add",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip', 'atendimento_ia')
      expect(conversation.reload.label_list).to contain_exactly('vip', 'atendimento_ia')
    end
  end

  describe 'POST /api/v1/conversations/:conversation_id/labels/remove' do
    it 'removes a single label without disturbing the others, with no prior read' do
      post "/api/v1/conversations/#{conversation.id}/labels",
           params: { labels: %w[vip atendimento_ia] }, headers: headers, as: :json

      post "/api/v1/conversations/#{conversation.id}/labels/remove",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip')
      expect(conversation.reload.label_list).to contain_exactly('vip')
    end

    it 'is a no-op when the label is not present' do
      post "/api/v1/conversations/#{conversation.id}/labels",
           params: { labels: ['vip'] }, headers: headers, as: :json

      post "/api/v1/conversations/#{conversation.id}/labels/remove",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip')
    end
  end
end
