# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::HttpRequestService do
  let(:agent_bot) { AgentBot.create!(name: 'Bot', outgoing_url: 'https://bot.example') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:payload) do
    { event: 'message_created', message_type: 'incoming', content: 'hi',
      conversation: { id: conversation.id } }
  end
  let(:service) { described_class.new(agent_bot, payload) }

  describe '#perform' do
    it 'does not return a truthy value when the HTTP call raises' do
      stub_request(:post, agent_bot.outgoing_url).to_raise(Errno::ECONNREFUSED)

      result = service.perform

      expect(result).to be_falsey
    end
  end
end
