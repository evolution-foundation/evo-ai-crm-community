# frozen_string_literal: true

require 'rails_helper'

# Reproduces the "split conversation" bug: a contact created manually in the
# CRM (Contact#phone_number normalized via Whatsapp::PhoneNumberNormalizer)
# already has a ContactInbox on the Evolution API (non-Go) inbox. When the
# real WhatsApp message later arrives, the webhook handler computes a
# source_id for the same phone number using a different, older normalizer
# (Whatsapp::IncomingMessageServiceHelpers#normalised_brazil_mobile_number),
# which disagrees with PhoneNumberNormalizer for DDD >= 31 mobiles. The
# builder finds the right Contact (phone lookup is normalizer-aligned) but,
# for the Evolution API provider, had no equivalent of Evolution Go's smart
# lookup — so it created a second ContactInbox with the divergent source_id,
# losing the pipeline stage/tags attached to the first conversation.
RSpec.describe ContactInboxWithContactBuilder do
  let(:channel) do
    Channel::Whatsapp.new(
      phone_number: '+5511100000000',
      provider: 'evolution',
      provider_config: { 'api_url' => 'https://evolution.example.com', 'admin_token' => 'x' }
    ).tap { |c| c.save(validate: false) }
  end
  let(:inbox) { Inbox.create!(name: 'Evolution Inbox', channel: channel) }

  # DDD 74 (>= 31): PhoneNumberNormalizer strips the nono dígito, the older
  # normalised_brazil_mobile_number does not touch an already-13-digit input.
  let(:canonical_source_id) { '557499879409' } # what Contact#phone_number/manual creation stores
  let(:webhook_source_id) { '5574999879409' } # what the old webhook normalizer produces

  let(:contact) { Contact.create!(name: 'Manually created lead', phone_number: "+#{canonical_source_id}") }
  let!(:existing_contact_inbox) do
    ContactInbox.create!(contact: contact, inbox: inbox, source_id: canonical_source_id)
  end

  it 'reuses the manually created ContactInbox instead of creating a duplicate with the divergent source_id' do
    result = described_class.new(
      inbox: inbox,
      source_id: webhook_source_id,
      contact_attributes: { name: 'Manually created lead', phone_number: "+#{webhook_source_id}" }
    ).perform

    expect(result.id).to eq(existing_contact_inbox.id)
    expect(ContactInbox.where(contact: contact, inbox: inbox).count).to eq(1)
  end

  context 'when the channel provider is waha' do
    let(:inbox) { create(:inbox, channel: create(:channel_whatsapp, provider: 'waha', phone_number: '+551199999999x')) }

    it 'is reconcilable' do
      builder = described_class.new(source_id: '5511988887777@c.us', inbox: inbox, contact_attributes: {})
      expect(builder.reconcilable_whatsapp_channel?).to eq(true)
    end

    it 'reuses an existing ContactInbox for the same contact when source_id has drifted' do
      contact = create(:contact, phone_number: '+5511988887777')
      existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '551188887777@c.us')

      builder = described_class.new(
        source_id: '5511988887777@c.us',
        inbox: inbox,
        contact_attributes: { phone_number: '+5511988887777' }
      )
      result = builder.perform

      expect(result.id).to eq(existing_contact_inbox.id)
      expect(result.reload.source_id).to eq('5511988887777@c.us')
    end
  end
end
