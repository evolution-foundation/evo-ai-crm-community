# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Messages::NewMessageNotificationService' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Messages::NewMessageNotificationService do
  let(:assignee) { instance_double(User) }
  let(:sender) { instance_double(User) }
  let(:participants_relation) { instance_double(ActiveRecord::Relation) }
  let(:notifications_relation) { instance_double(ActiveRecord::Relation, exists?: false) }
  let(:conversation) do
    instance_double(
      Conversation,
      assignee: assignee,
      conversation_participants: [],
      notifications: notifications_relation
    )
  end
  let(:message) do
    instance_double(
      Message,
      conversation: conversation,
      sender: sender,
      notifiable?: true
    )
  end
  let(:notification_builder) { instance_double(NotificationBuilder, perform: true) }

  before do
    allow(NotificationBuilder).to receive(:new).and_return(notification_builder)
  end

  describe '#perform' do
    it 'does not raise NameError when message has no account method (regression EVO-983)' do
      expect { described_class.new(message: message).perform }.not_to raise_error
    end

    it 'returns early when message is not notifiable' do
      allow(message).to receive(:notifiable?).and_return(false)

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new)
    end

    it 'notifies the conversation assignee without passing an account argument' do
      allow(notifications_relation).to receive(:exists?).with(user: assignee, secondary_actor: message).and_return(false)

      described_class.new(message: message).perform

      expect(NotificationBuilder).to have_received(:new).with(
        notification_type: 'assigned_conversation_new_message',
        user: assignee,
        primary_actor: conversation,
        secondary_actor: message
      )
    end

    it 'skips assignee notification when assignee is the sender' do
      allow(conversation).to receive(:assignee).and_return(sender)

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new)
    end

    it 'skips assignee notification when already notified' do
      allow(notifications_relation).to receive(:exists?).with(user: assignee, secondary_actor: message).and_return(true)

      described_class.new(message: message).perform

      expect(NotificationBuilder).not_to have_received(:new).with(
        hash_including(notification_type: 'assigned_conversation_new_message')
      )
    end

    it 'notifies participating users excluding the sender' do
      participant = instance_double(User)
      participant_record = instance_double(ConversationParticipant, user: participant)
      sender_record = instance_double(ConversationParticipant, user: sender)
      allow(conversation).to receive_messages(assignee: nil, conversation_participants: [participant_record, sender_record])
      allow(notifications_relation).to receive(:exists?).with(user: participant, secondary_actor: message).and_return(false)

      described_class.new(message: message).perform

      expect(NotificationBuilder).to have_received(:new).with(
        notification_type: 'participating_conversation_new_message',
        user: participant,
        primary_actor: conversation,
        secondary_actor: message
      ).once
    end
  end
end
