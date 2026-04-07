# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionCableListener do
  let(:listener) { described_class.instance }
  let(:user) do
    User.create!(name: 'Agent', email: "listener-#{SecureRandom.hex(4)}@test.com")
  end
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://listener.example.com') }
  let(:inbox) do
    ib = Inbox.create!(name: 'Listener Inbox', channel: channel)
    InboxMember.create!(inbox: ib, user: user)
    ib
  end
  let(:contact) { Contact.create!(name: 'LC', email: "lc-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: "lc-#{SecureRandom.hex(4)}") }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:message) do
    Message.create!(
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Test message'
    )
  end

  EventData = Struct.new(:data)

  describe '#message_created' do
    it 'enqueues broadcast via perform_later for MESSAGE_CREATED' do
      event = EventData.new({ message: message })

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        anything,
        Events::Types::MESSAGE_CREATED,
        anything
      )

      listener.message_created(event)
    end
  end

  describe '#conversation_created' do
    it 'enqueues broadcast via perform_later for CONVERSATION_CREATED' do
      event = EventData.new({ conversation: conversation })

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        anything,
        Events::Types::CONVERSATION_CREATED,
        anything
      )

      listener.conversation_created(event)
    end
  end

  describe 'broadcast routing' do
    it 'skips broadcast when tokens are blank' do
      expect(ActionCableBroadcastJob).not_to receive(:perform_later)

      listener.send(:broadcast, nil, [], Events::Types::MESSAGE_CREATED, { id: 1 })
    end
  end
end
