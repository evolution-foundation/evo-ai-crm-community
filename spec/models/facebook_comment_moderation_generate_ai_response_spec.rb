# frozen_string_literal: true

require 'rails_helper'

# Approving a flagged comment asks the inbox's agent for a reply. Unlinking the agent
# keeps the binding row, inactive, so the row alone must not be read as "has an agent".
RSpec.describe FacebookCommentModeration, '#generate_ai_response' do
  let(:agent_bot) { AgentBot.create!(name: 'Moderation Bot', outgoing_url: 'https://example.test/bot') }
  let(:inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Moderation Inbox') }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:message) { conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'comentario', sender: contact) }
  let(:moderation) do
    described_class.create!(conversation: conversation, message: message, comment_id: "c-#{SecureRandom.hex(4)}",
                            moderation_type: 'explicit_words', action_type: 'delete_comment', status: 'pending')
  end

  it 'queues the reply when the agent is linked' do
    AgentBotInbox.create!(inbox: inbox, agent_bot: agent_bot, status: :active)

    expect { expect(moderation.generate_ai_response).to be(true) }
      .to have_enqueued_job(Facebook::Moderation::GenerateResponseJob)
  end

  it 'stays silent when the agent was unlinked' do
    AgentBotInbox.create!(inbox: inbox, agent_bot: agent_bot, status: :inactive)
    # The method rescues everything into false; an error would pass this for the wrong reason.
    expect(Rails.logger).not_to receive(:error)

    expect { expect(moderation.generate_ai_response).to be(false) }
      .not_to have_enqueued_job(Facebook::Moderation::GenerateResponseJob)
  end
end
