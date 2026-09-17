# frozen_string_literal: true

require 'rails_helper'

# send_response is only reachable from approve!(user), which persists moderated_by before
# executing. Leaving the reply authorless there is not neutral: unlike a device echo it carries
# no origin marker, so human_response? refuses it and the answered conversation keeps its
# waiting clock running and never records a first reply.
RSpec.describe Facebook::Moderation::ActionExecutorService do
  let(:approver) { User.create!(name: 'Approver', email: "approver-#{SecureRandom.hex(4)}@test.com") }
  let(:bot) { AgentBot.create!(name: "Bot #{SecureRandom.hex(3)}", description: 'bot', outgoing_url: 'https://example.com/bot') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:comment_message) { conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'comentario', sender: contact) }
  let(:moderation) do
    FacebookCommentModeration.create!(conversation: conversation, message: comment_message,
                                      comment_id: "c-#{SecureRandom.hex(4)}", moderation_type: 'response_approval',
                                      action_type: 'send_response', response_content: 'resposta',
                                      status: 'approved', moderated_by: approver)
  end
  let(:service) { described_class.new(moderation) }

  def attributes
    service.send(:build_message_attributes, conversation, 'resposta', moderation.comment_id)
  end

  it 'credits the operator who approved when no bot drafted the reply' do
    expect(attributes[:sender]).to eq(approver)
  end

  it 'credits the bot that drafted it, ahead of the operator' do
    allow(service).to receive(:find_agent_bot_for_moderation).and_return(bot)

    expect(attributes[:sender]).to eq(bot)
  end

  it 'never reaches for a user who is not part of the moderation' do
    stranger = User.create!(name: 'Stranger', email: "stranger-#{SecureRandom.hex(4)}@test.com")

    expect(attributes[:sender]).not_to eq(stranger)
  end

  it 'keeps the approved reply counting as an answer to the customer' do
    conversation.update!(waiting_since: 1.hour.ago)
    conversation.messages.create!(attributes)

    expect(conversation.reload.waiting_since).to be_nil
    expect(conversation.reload.first_reply_created_at).to be_present
  end
end
