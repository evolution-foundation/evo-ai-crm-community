# frozen_string_literal: true

require 'rails_helper'

# A reply typed on the phone has no sender, so the first_response event it produces has no
# user to name. Falling back to the conversation owner is what keeps that reply on the agent
# reports; without the fallback the event is written unattributed and the agent breakdown,
# which filters user_id out, simply loses it.
RSpec.describe ReportingEventListener do
  let(:listener) { described_class.instance }
  let(:agent) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def device_echo
    conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'respondi pelo celular',
                                  content_attributes: { sent_from_device: true })
  end

  def fire(message)
    listener.first_reply_created(Events::Base.new('first.reply.created', Time.zone.now, { message: message }))
    ReportingEvent.find_by(name: 'first_response', conversation_id: conversation.id)
  end

  describe '#first_reply_created' do
    it 'credits the reply to whoever owns the conversation' do
      conversation.update!(assignee: agent)

      expect(fire(device_echo).user_id).to eq(agent.id)
    end

    it 'leaves it unattributed when nobody owns the conversation' do
      expect(fire(device_echo).user_id).to be_nil
    end

    it 'still credits the agent who replied from the CRM, not the owner' do
      other = User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@test.com")
      conversation.update!(assignee: other)
      message = conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'oi', sender: agent)

      expect(fire(message).user_id).to eq(agent.id)
    end
  end
end
