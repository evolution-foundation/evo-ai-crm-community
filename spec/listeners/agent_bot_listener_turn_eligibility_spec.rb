# frozen_string_literal: true

require 'rails_helper'

# CRM-212 (reopened): process_message_event is only reached once every
# skip_for_gate? check has already passed, i.e. right when the turn actually
# starts. It stamps a short-lived Redis marker here so MessageCreator can
# trust "this conversation was eligible when we dispatched" even if a label
# is removed mid-turn by the time the bot's reply comes back.
RSpec.describe AgentBotListener do
  let(:listener) { described_class.instance }
  let(:agent_bot) { instance_double(AgentBot, id: SecureRandom.uuid, outgoing_url: '', webhook_provider?: false, n8n_provider?: false) }
  let(:conversation) { instance_double(Conversation, id: SecureRandom.uuid) }
  let(:message) { instance_double(Message, webhook_data: {}, conversation: conversation) }

  after { Redis::Alfred.delete(format(Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY, conversation_id: conversation.id)) }

  it 'stamps the turn-start eligibility marker for the conversation' do
    listener.send(:process_message_event, 'message_created', agent_bot, message, {})

    key = format(Redis::RedisKeys::AGENT_BOT_TURN_ELIGIBLE_KEY, conversation_id: conversation.id)
    expect(Redis::Alfred.get(key)).to be_present
  end
end
