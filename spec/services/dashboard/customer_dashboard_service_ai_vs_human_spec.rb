# frozen_string_literal: true

require 'rails_helper'

# The human/AI split reads authorship off the message sender and off reporting_events.user_id.
# A reply typed on the phone has neither, so without the device marker it drops to the AI side
# of both halves and the panel reports the customer was answered by a bot.
RSpec.describe Dashboard::CustomerDashboardService do
  let(:bot) { AgentBot.create!(name: "Bot #{SecureRandom.hex(3)}", description: 'bot', outgoing_url: 'https://example.com/bot') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:result) { described_class.new(params: {}).call[:ai_vs_human] }

  def conversation
    contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4))
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def first_response!(conv, value)
    ReportingEvent.create!(name: 'first_response', value: value, conversation: conv, inbox_id: inbox.id, user_id: nil)
  end

  describe 'message counts' do
    it 'counts a reply typed on the phone as human' do
      conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'pelo celular',
                                    content_attributes: { sent_from_device: true })

      expect(result).to include(human_messages_count: 1, ai_messages_count: 0)
    end

    it 'still counts a bot reply as AI' do
      conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'bot', sender: bot)

      expect(result).to include(ai_messages_count: 1, human_messages_count: 0)
    end
  end

  describe 'first response averages' do
    it 'puts an unattributed event from a phone reply on the human side' do
      conv = conversation
      conv.messages.create!(inbox: inbox, message_type: :outgoing, content: 'pelo celular',
                            content_attributes: { sent_from_device: true })
      first_response!(conv, 100)

      expect(result).to include(avg_first_response_time_human_seconds: 100.0,
                                avg_first_response_time_ai_seconds: 0.0)
    end

    it 'leaves an unattributed event with no phone reply on the AI side' do
      first_response!(conversation, 300)

      expect(result).to include(avg_first_response_time_ai_seconds: 300.0,
                                avg_first_response_time_human_seconds: 0.0)
    end
  end
end
