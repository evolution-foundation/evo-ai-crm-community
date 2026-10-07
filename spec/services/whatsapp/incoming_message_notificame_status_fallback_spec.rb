# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageNotificameService, '#process_status_update fallback' do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:params) do
    { type: 'MESSAGE_STATUS', messageId: 'unknown-id',
      messageStatus: { providerMessageId: 'unknown-provider-id', code: 'DELIVERED' } }
  end

  def add_outgoing(created_at)
    conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'resposta', created_at: created_at)
  end

  # A status webhook whose message cannot be found falls back to "the latest outgoing message of
  # the inbox". Message has default_scope { order(created_at: :asc) }, which an appended
  # order(created_at: :desc) does not override, so the fallback hit the OLDEST outgoing message and
  # rewrote its status and source id with an unrelated webhook.
  it 'updates the latest outgoing message, never the oldest' do
    add_outgoing(3.days.ago)
    latest = add_outgoing(1.minute.ago)

    expect(Messages::StatusUpdateService).to receive(:new).with(latest, 'delivered', nil).and_return(double(perform: true))

    described_class.new(inbox: inbox, params: params).perform
  end

  # Outgoing messages can share a created_at (provider timestamps have second precision), so the
  # fallback must pick deterministically: the one with the higher id.
  it 'breaks a created_at tie deterministically' do
    tied_at = 1.minute.ago
    winner = [add_outgoing(tied_at), add_outgoing(tied_at)].max_by(&:id)

    expect(Messages::StatusUpdateService).to receive(:new).with(winner, 'delivered', nil).and_return(double(perform: true))

    described_class.new(inbox: inbox, params: params).perform
  end
end
