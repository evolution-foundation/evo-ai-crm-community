# frozen_string_literal: true

require 'rails_helper'

# A WhatsApp read receipt (or any other status-only transition) touches the
# same incoming Message row and fires message_updated again, with no change
# to what the customer actually said. Without this guard, that re-ran the
# whole bot dispatch and produced a second, redundant AI reply to content
# message_created had already answered a few seconds earlier.
RSpec.describe AgentBotListener do
  describe '#message_updated' do
    let(:listener) { described_class.instance }
    let(:agent_bot) do
      AgentBot.create!(name: 'bot', outgoing_url: 'https://bot.example', bot_provider: 'evo_ai', api_key: 'k')
    end
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
    let!(:agent_bot_inbox) { AgentBotInbox.create!(inbox: inbox, agent_bot: agent_bot) }
    let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:message) do
      Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Software')
    end

    def build_event(changed_attributes)
      Events::Base.new('message_updated', Time.current, message: message, changed_attributes: changed_attributes)
    end

    before do
      allow(BotRuntime::Config).to receive(:enabled?).and_return(false)
      allow(AgentBots::HttpRequestJob).to receive(:perform_later)
    end

    it 'does not dispatch another bot turn on a status-only update (e.g. a read receipt)' do
      listener.message_updated(build_event({ 'status' => %w[sent read] }))

      expect(AgentBots::HttpRequestJob).not_to have_received(:perform_later)
    end

    it 'still dispatches when the content actually changed' do
      listener.message_updated(build_event({ 'content' => ['old text', 'Software'] }))

      expect(AgentBots::HttpRequestJob).to have_received(:perform_later)
    end
  end
end
