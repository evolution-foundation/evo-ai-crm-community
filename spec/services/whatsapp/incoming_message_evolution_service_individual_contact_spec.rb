# frozen_string_literal: true

require 'rails_helper'

# Regression coverage: the Evolution API webhook must derive source_id with
# Whatsapp::PhoneNumberNormalizer — the same canonical form Contact#phone_number
# uses everywhere else — not the older Brazil-only normalizer, which disagreed
# for DDD >= 31 mobiles and split manually-created contacts from real ones.
RSpec.describe Whatsapp::IncomingMessageEvolutionService do
  let(:provider_service) { instance_double(Whatsapp::Providers::EvolutionService) }
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution', provider_service: provider_service) }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:contact) { instance_double(Contact, name: 'Bob', update!: true) }
  let(:contact_inbox) { instance_double(ContactInbox, id: 7, contact: contact, source_id: '557499879409') }
  let(:builder) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox) }

  let(:service) { described_class.new(inbox: inbox, params: { event: 'messages.upsert', data: {} }) }

  # DDD 74 (>= 31), wa_id already carries the nono dígito, as Meta/Evolution
  # always report the current mobile format.
  let(:individual_message_payload) do
    {
      key: { id: 'msg-3', remoteJid: '5574999879409@s.whatsapp.net', fromMe: false },
      pushName: 'Bob',
      messageTimestamp: 1_700_000_002,
      message: { conversation: 'oi' }
    }
  end

  before do
    service.instance_variable_set(:@inbox, inbox)
    service.instance_variable_set(:@raw_message, individual_message_payload)
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
    allow(service).to receive(:update_contact_profile_picture)
  end

  it 'builds the ContactInbox with the canonical (PhoneNumberNormalizer) source_id, not the raw/legacy one' do
    expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
      expect(args[:source_id]).to eq('557499879409')
      builder
    end

    service.send(:set_contact)
  end
end
