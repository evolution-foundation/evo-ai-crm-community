# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Widget Messages API', type: :request do
  let(:web_widget_channel) { Channel::WebWidget.create!(website_url: 'https://example.com') }
  let(:inbox) { Inbox.create!(name: 'Widget', channel: web_widget_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }

  let(:auth_token) do
    Widget::TokenService.new(payload: { inbox_id: inbox.id, source_id: contact_inbox.source_id }).generate_token
  end

  let(:headers) { { 'X-Auth-Token' => auth_token } }

  def post_message
    post '/api/v1/widget/messages',
         params: { website_token: web_widget_channel.website_token, message: { content: 'hello' } },
         headers: headers, as: :json
  end

  describe 'POST create on an archived inbox' do
    it 'rejects the message without creating it' do
      contact_inbox
      inbox.update!(archived_at: Time.current)

      expect { post_message }.not_to change(Message, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'POST create on an active inbox' do
    it 'creates the message' do
      contact_inbox

      expect { post_message }.to change(Message, :count).by(1)

      expect(response).to have_http_status(:success)
    end
  end
end
