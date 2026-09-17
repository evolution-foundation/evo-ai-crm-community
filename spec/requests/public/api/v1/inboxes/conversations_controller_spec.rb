# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public Inbound Conversations API', type: :request do
  let(:api_channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: api_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }

  let(:path) do
    "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations"
  end

  describe 'POST create on an archived inbox' do
    it 'rejects the conversation without creating it' do
      contact_inbox
      inbox.update!(archived_at: Time.current)

      expect do
        post path, params: {}, as: :json
      end.not_to change(Conversation, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
