# frozen_string_literal: true

require 'rails_helper'

# Evolution Go groups: with group_mention_required the bot only answers when the
# inbox number is @-mentioned; every other group message must not reach the bot.
RSpec.describe AgentBotListener do
  let(:listener) { described_class.instance }
  let(:message) { instance_double(Message, id: 'msg-1', conversation: instance_double(Conversation, id: 'conv-1')) }

  it 'skips when the agent bot inbox reports a group mention block' do
    agent_bot_inbox = instance_double(AgentBotInbox, group_mention_block_reason: 'group message without mention')

    expect(listener.send(:skip_for_group_mention?, agent_bot_inbox, message)).to be(true)
  end

  it 'does not skip when there is no block reason' do
    agent_bot_inbox = instance_double(AgentBotInbox, group_mention_block_reason: nil)

    expect(listener.send(:skip_for_group_mention?, agent_bot_inbox, message)).to be(false)
  end

  it 'does not skip without an agent bot inbox' do
    expect(listener.send(:skip_for_group_mention?, nil, message)).to be(false)
  end
end
