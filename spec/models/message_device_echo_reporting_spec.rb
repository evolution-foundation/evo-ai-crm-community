# frozen_string_literal: true

require 'rails_helper'

# A reply typed on the phone has no user to credit it to, but it is still an agent answering
# a customer. Reporting that reads authorship off `sender_type` has to see it as one, or the
# dashboard starts claiming the customer was never answered.
RSpec.describe Message do
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

  describe '.human_outgoing' do
    it 'counts a reply typed on the phone' do
      expect(described_class.human_outgoing).to include(device_echo)
    end

    it 'counts a reply sent from the CRM by an agent' do
      message = conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'oi', sender: agent)

      expect(described_class.human_outgoing).to include(message)
    end

    it 'leaves an inbound message out' do
      message = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', sender: contact)

      expect(described_class.human_outgoing).not_to include(message)
    end
  end

  describe 'a reply typed on the phone' do
    before { conversation.update!(waiting_since: 1.hour.ago) }

    # The prior-outgoing guard in valid_first_reply? filters with IS DISTINCT FROM because a
    # device echo has a null sender_type, and `where.not` drops null rows: with the echo
    # invisible the guard undercounts and a later reply is still taken for the first one.
    it 'is counted among the replies that already went out' do
      2.times { device_echo }
      conversation.update!(first_reply_created_at: nil)
      later = conversation.messages.build(inbox: inbox, message_type: :outgoing, content: 'de novo',
                                          content_attributes: { sent_from_device: true })

      expect(later.send(:valid_first_reply?)).to be(false)
    end

    it 'stops the clock the customer is waiting on' do
      device_echo

      expect(conversation.reload.waiting_since).to be_nil
    end

    it 'records the conversation as answered' do
      device_echo

      expect(conversation.reload.first_reply_created_at).to be_present
    end
  end
end
