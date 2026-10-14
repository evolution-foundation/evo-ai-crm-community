# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::InactivityActionsService do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  subject(:service) { described_class.new(conversation, nil) }

  def add_incoming(created_at)
    conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', created_at: created_at)
  end

  # Message has default_scope { order(created_at: :asc) }, which an appended
  # order(created_at: :desc) does not override: "the last incoming message" was really the
  # OLDEST one, so a conversation the customer was actively writing in looked long inactive.
  describe 'inactive time' do
    it 'is measured from the latest customer message, not the oldest' do
      add_incoming(3.days.ago)
      add_incoming(5.minutes.ago)

      expect(service.send(:calculate_inactive_time_minutes)).to be_between(4, 6)
    end

    it 'falls back to the conversation creation time when the customer never wrote' do
      conversation.update_columns(created_at: 90.minutes.ago)

      expect(service.send(:calculate_inactive_time_minutes)).to be_between(89, 91)
    end
  end
end
