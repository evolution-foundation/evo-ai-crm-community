# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBotListener do
  let(:listener) { described_class.instance }
  let(:agent_bot) { instance_double(AgentBot, name: 'bot') }
  let(:conversation) { instance_double(Conversation, display_id: 7) }
  let(:message) { instance_double(Message) }
  let(:service) { instance_double(BotRuntime::DelegationService, delegate: true) }

  before do
    allow(listener).to receive_messages(find_conversation_from_payload: conversation,
                                        create_message_from_payload: message)
    allow(BotRuntime::DelegationService).to receive(:new).and_return(service)
  end

  def delegate(event, message_type = 'incoming')
    listener.send(:delegate_to_bot_runtime, agent_bot, { event: event, message_type: message_type, content: 'hi' })
  end

  it 'delegates a new incoming message' do
    delegate('message_created')
    expect(service).to have_received(:delegate).once
  end

  it 'accepts the integer incoming message type' do
    delegate('message_created', 0)
    expect(service).to have_received(:delegate).once
  end

  it 'does not delegate an update of an incoming message again' do
    delegate('message_updated')
    expect(BotRuntime::DelegationService).not_to have_received(:new)
  end

  it 'does not delegate an outgoing message' do
    delegate('message_created', 'outgoing')
    expect(BotRuntime::DelegationService).not_to have_received(:new)
  end
end
