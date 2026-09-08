# frozen_string_literal: true

require 'rails_helper'

# CRM-546: the realtime audience of a conversation is inbox members plus
# administrators, widened in what the events hand to user_tokens (never inside it).
RSpec.describe ActionCableListener do
  let(:listener) { described_class.instance }
  let(:admin_role) { Role.create!(key: 'administrator', name: 'Administrator') }
  let(:agent_role) { Role.create!(key: 'agent', name: 'Agent') }
  let(:member) { User.create!(name: 'Member', email: "member-#{SecureRandom.hex(4)}@test.com") }
  let(:admin) { User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@test.com") }
  let(:agent) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://audience.example.com') }
  let(:inbox) { Inbox.create!(name: 'Audience Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Visitor', email: "visitor-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: "aud-#{SecureRandom.hex(4)}") }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    InboxMember.create!(inbox: inbox, user: member)
    UserRole.create!(user: admin, role: admin_role)
    UserRole.create!(user: agent, role: agent_role)
  end

  describe '#audience' do
    it 'is the inbox members plus every administrator, without duplicates' do
      UserRole.create!(user: member, role: admin_role)

      audience = listener.send(:audience, conversation)

      expect(audience).to contain_exactly(member, admin)
    end

    it 'reaches administrators even when the inbox has no members' do
      InboxMember.where(inbox: inbox).destroy_all

      expect(listener.send(:audience, conversation)).to contain_exactly(admin)
    end

    it 'never includes an agent who is not a member' do
      expect(listener.send(:audience, conversation)).not_to include(agent)
    end

    it 'falls back to members only when there is no administrator' do
      UserRole.where(role: admin_role).destroy_all

      expect(listener.send(:audience, conversation)).to contain_exactly(member)
    end

    # Mirrors the auth's effective-role rule: a newer grant replaces the older one.
    context 'when a user changed role' do
      let(:demoted) { User.create!(name: 'Demoted', email: "demoted-#{SecureRandom.hex(4)}@test.com") }
      let(:promoted) { User.create!(name: 'Promoted', email: "promoted-#{SecureRandom.hex(4)}@test.com") }

      it 'drops an admin row superseded by a newer agent row' do
        UserRole.create!(user: demoted, role: admin_role, created_at: 2.days.ago)
        UserRole.create!(user: demoted, role: agent_role, created_at: 1.minute.ago)

        expect(listener.send(:audience, conversation)).not_to include(demoted)
      end

      it 'admits an agent row superseded by a newer admin row' do
        UserRole.create!(user: promoted, role: agent_role, created_at: 2.days.ago)
        UserRole.create!(user: promoted, role: admin_role, created_at: 1.minute.ago)

        expect(listener.send(:audience, conversation)).to include(promoted)
      end

      it 'ignores derived roles even when they are the newest row' do
        derived = Role.create!(key: "evo_derived_#{admin.id}_global", name: "Derived #{admin.id}")
        UserRole.create!(user: admin, role: derived, created_at: 1.second.ago)

        expect(listener.send(:audience, conversation)).to include(admin)
      end
    end
  end

  describe 'every conversation event widens its audience' do
    let(:message) { Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'hi') }
    let(:events) do
      conversation_data = { conversation: conversation }
      {
        message_created: { message: message },
        message_updated: { message: message, previous_changes: {} },
        first_reply_created: { message: message },
        conversation_created: conversation_data,
        conversation_read: conversation_data,
        conversation_status_changed: conversation_data,
        conversation_updated: conversation_data,
        conversation_typing_on: { conversation: conversation, user: member },
        conversation_typing_off: { conversation: conversation, user: member },
        assignee_changed: conversation_data,
        team_changed: conversation_data,
        conversation_contact_changed: conversation_data
      }
    end

    it 'resolves the audience for the conversation on each of them' do
      message # created before spying: its own commit callbacks dispatch real events
      allow(ActionCableBroadcastJob).to receive(:perform_later)
      allow(listener).to receive(:audience).and_call_original

      events.each { |method, data| listener.public_send(method, Struct.new(:data).new(data)) }

      expect(listener).to have_received(:audience).with(conversation).exactly(events.size).times
    end
  end

  describe '#realtime_readers cache' do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    it 'resolves the administrator ids once per TTL' do
      allow(listener).to receive(:administrator_ids).and_call_original

      2.times { listener.send(:realtime_readers, conversation) }

      expect(listener).to have_received(:administrator_ids).once
    end
  end

  describe 'message.created' do
    it 'is enqueued for the members and the administrators, not for other agents' do
      message = Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'hi')
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(Struct.new(:data).new({ message: message }))

      expect(ActionCableBroadcastJob).to have_received(:perform_later) do |tokens, event_name, _payload|
        expect(event_name).to eq(Events::Types::MESSAGE_CREATED)
        expect(tokens).to include(member.pubsub_token, admin.pubsub_token)
        expect(tokens).not_to include(agent.pubsub_token)
      end
    end
  end

  describe '#user_tokens (CRM-185 guard stays)' do
    it 'still returns only the tokens of the agents it is given' do
      expect(listener.send(:user_tokens, nil, [member])).to eq([member.pubsub_token])
      expect(listener.send(:user_tokens, nil, [])).to eq([])
    end
  end
end
