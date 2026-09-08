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
  end

  describe '#realtime_readers cache' do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    it 'resolves the administrator ids once per TTL' do
      allow(User).to receive(:joins).and_call_original

      2.times { listener.send(:realtime_readers, conversation) }

      expect(User).to have_received(:joins).once
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
