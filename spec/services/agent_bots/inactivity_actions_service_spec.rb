# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::InactivityActionsService do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Inactivity Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Inactivity Contact') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open) }
  let(:agent_bot) do
    AgentBot.create!(
      name: 'Inactivity Bot',
      bot_provider: :webhook_provider,
      bot_config: { 'inactivity_actions' => [{ 'minutes' => 5, 'action' => 'interact', 'message' => 'Ainda por aqui?' }] }
    )
  end

  def incoming(content, at)
    conversation.messages.create!(inbox: inbox, message_type: :incoming, sender: contact, content: content, created_at: at)
  end

  before { incoming('primeira', 30.minutes.ago) }

  it 'does not act when the customer replied after the first message' do
    incoming('resposta', 1.minute.ago)

    expect { described_class.new(conversation.reload, agent_bot).process }
      .not_to change(InactivityActionExecution, :count)
  end

  it 'acts once the latest reply is older than the configured minutes' do
    incoming('resposta', 6.minutes.ago)

    expect { described_class.new(conversation.reload, agent_bot).process }
      .to change(InactivityActionExecution, :count).by(1)
  end
end
