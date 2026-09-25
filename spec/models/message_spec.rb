# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Message do
  include ActiveSupport::Testing::TimeHelpers

  describe '#refresh_conversation_activity!' do
    it 'uses current time when requested even if created_at is older' do
      conversation = double('Conversation', id: 'conv_1', class: Conversation)
      relation = double('Relation')
      message = described_class.new(created_at: 2.days.ago)
      allow(message).to receive(:conversation).and_return(conversation)

      travel_to(Time.zone.parse('2026-02-12 10:00:00')) do
        allow(Conversation).to receive(:where).with(id: 'conv_1').and_return(relation)
        expect(relation).to receive(:update_all).with(
          [
            'last_activity_at = GREATEST(COALESCE(last_activity_at, ?), ?), updated_at = ?',
            Time.current,
            Time.current,
            Time.current
          ]
        )

        message.refresh_conversation_activity!(message.created_at, use_current_time: true)
      end
    end

    it 'uses only provided timestamp when use_current_time is false' do
      older_time = Time.zone.parse('2026-02-10 10:00:00')
      conversation = double('Conversation', id: 'conv_2', class: Conversation)
      relation = double('Relation')
      message = described_class.new(created_at: older_time)
      allow(message).to receive(:conversation).and_return(conversation)

      travel_to(Time.zone.parse('2026-02-12 11:00:00')) do
        allow(Conversation).to receive(:where).with(id: 'conv_2').and_return(relation)
        expect(relation).to receive(:update_all).with(
          [
            'last_activity_at = GREATEST(COALESCE(last_activity_at, ?), ?), updated_at = ?',
            older_time,
            older_time,
            Time.current
          ]
        )

        message.refresh_conversation_activity!(message.created_at, use_current_time: false)
      end
    end
  end

  describe '#imported?' do
    let(:contact) { Contact.create!(name: 'Imported Spec Contact', email: "imported-#{SecureRandom.hex(4)}@example.com") }
    let(:inbox) { Inbox.create!(name: "Imported Spec Inbox #{SecureRandom.hex(2)}", channel: Channel::Api.create!) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    it 'defaults to live' do
      message = described_class.new
      expect(message.source).to eq('live')
      expect(message.live?).to be(true)
      expect(message.imported?).to be(false)
    end

    it 'skips after_create_commit callbacks when imported' do
      message = described_class.new(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'imported hello',
        source: :imported
      )

      expect(message).not_to receive(:execute_after_create_commit_callbacks)
      expect(message).not_to receive(:publish_message_created)
      expect(message).not_to receive(:sync_message_event)

      message.save!
    end

    it 'skips prevent_message_flooding when imported' do
      allow(Limits).to receive(:conversation_message_per_minute_limit).and_return(100)

      100.times do |i|
        described_class.create!(
          inbox: inbox,
          conversation: conversation,
          message_type: :incoming,
          content: "live-#{i}"
        )
      end

      live_attempt = described_class.new(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'over-the-limit'
      )
      expect(live_attempt).not_to be_valid
      expect(live_attempt.errors[:base]).to include('Too many messages')

      imported = described_class.new(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'imported-past-the-cap',
        source: :imported
      )
      expect(imported).to be_valid
    end
  end

  describe '#apply_agent_bot_signature' do
    let(:contact) { Contact.create!(name: 'Signature Spec Contact', email: "signature-#{SecureRandom.hex(4)}@example.com") }
    let(:inbox) { Inbox.create!(name: "Signature Spec Inbox #{SecureRandom.hex(2)}", channel: Channel::Api.create!) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:agent_bot) do
      AgentBot.create!(name: 'Atendente', bot_type: :webhook, bot_provider: :webhook_provider,
                       debounce_time: 5, message_signature: 'Atendente')
    end

    it 'prefixes an outgoing AgentBot message with the bold display name, once' do
      message = conversation.messages.create!(
        inbox: inbox, message_type: :outgoing, sender: agent_bot, content: 'Pronto, já te encaminhei.'
      )

      expect(message.content).to eq("*Atendente:*\nPronto, já te encaminhei.")
    end

    it 'does not prefix when the AgentBot has no message_signature configured' do
      agent_bot.update!(message_signature: nil)
      message = conversation.messages.create!(
        inbox: inbox, message_type: :outgoing, sender: agent_bot, content: 'Sem assinatura.'
      )

      expect(message.content).to eq('Sem assinatura.')
    end

    it 'does not prefix an incoming message even when sender is an AgentBot' do
      message = conversation.messages.create!(
        inbox: inbox, message_type: :incoming, sender: agent_bot, content: 'eco de teste'
      )

      expect(message.content).to eq('eco de teste')
    end

    it 'does not prefix a human agent message' do
      user = User.create!(name: 'Leandro', email: "leandro-#{SecureRandom.hex(4)}@example.com")
      message = conversation.messages.create!(
        inbox: inbox, message_type: :outgoing, sender: user, content: 'resposta manual'
      )

      expect(message.content).to eq('resposta manual')
    end

    it 'does not double-prefix a message that already carries the signature' do
      message = conversation.messages.new(
        inbox: inbox, message_type: :outgoing, sender: agent_bot, content: "*Atendente:*\njá formatado"
      )
      message.valid?

      expect(message.content).to eq("*Atendente:*\njá formatado")
    end

    it 'does not prefix a private note even when sender is an AgentBot' do
      message = conversation.messages.create!(
        inbox: inbox, message_type: :outgoing, private: true, sender: agent_bot, content: 'nota interna'
      )

      expect(message.content).to eq('nota interna')
    end
  end

  describe '#set_conversation_activity' do
    it 'delegates to refresh_conversation_activity! with current time' do
      conversation = double('Conversation', last_activity_at: nil)
      message = described_class.new(created_at: 1.day.ago)
      allow(message).to receive(:conversation).and_return(conversation)

      expect(message).to receive(:refresh_conversation_activity!).with(message.created_at, use_current_time: true)

      message.send(:set_conversation_activity)
    end
  end
end
