# frozen_string_literal: true

require 'rails_helper'

# CRM-212 (reopened): conversation_eligible_for_bot_reply? re-checked the gate at
# delivery time, using labels as they are NOW — not as they were when the turn
# started. A stage automation (or the bot's own tool call) removing the
# eligibility label mid-turn silently dropped the LLM's already-generated final
# reply. AgentBotListener#process_message_event now stamps a short-lived
# "eligible at turn start" marker before dispatching; delivery trusts that
# marker as a grace window instead of re-deriving eligibility from scratch.
RSpec.describe AgentBots::MessageCreator do
  let(:agent_bot) { AgentBot.create!(name: 'Bot', outgoing_url: 'https://bot.example', bot_provider: 'webhook_provider') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: Channel::WebWidget.create!(website_url: 'https://test.example.com')) }
  let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:agent_bot_inbox) { instance_double(AgentBotInbox) }

  before do
    allow(AgentBotInbox).to receive(:find_by).with(agent_bot: agent_bot, inbox: inbox).and_return(agent_bot_inbox)
  end

  after { Redis::Alfred.delete(format(Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY, conversation_id: conversation.id)) }

  describe '#create_bot_reply' do
    context 'when the conversation is currently eligible' do
      before { allow(agent_bot_inbox).to receive(:processing_block_reason).with(conversation).and_return(nil) }

      it 'creates the reply' do
        message = described_class.new(agent_bot).create_bot_reply('hi', conversation)
        expect(message).to be_persisted
      end
    end

    context 'when the eligibility label was removed after the turn started (CRM-212)' do
      before do
        allow(agent_bot_inbox).to receive(:processing_block_reason).with(conversation)
                                                                   .and_return('no allowed label on conversation/contact')
      end

      it 'discards the reply when no turn-start marker exists' do
        message = described_class.new(agent_bot).create_bot_reply('hi', conversation)
        expect(message).to be_nil
        expect(conversation.messages.count).to eq(0)
      end

      it 'still delivers the reply within the turn-start grace window' do
        key = format(Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY, conversation_id: conversation.id)
        Redis::Alfred.setex(key, true, 10.minutes)

        message = described_class.new(agent_bot).create_bot_reply('hi', conversation)

        expect(message).to be_persisted
      end

      it 'discards the reply once the turn-start marker has expired' do
        key = format(Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY, conversation_id: conversation.id)
        Redis::Alfred.setex(key, true, 10.minutes)
        Redis::Alfred.delete(key) # simulate TTL expiry

        message = described_class.new(agent_bot).create_bot_reply('hi', conversation)

        expect(message).to be_nil
      end
    end
  end
end
