# frozen_string_literal: true

require 'rails_helper'

# Evolution Go: one person must not get a second ContactInbox because the phone
# arrives with or without "+" (rows written before the digits-only rule carry "+").
RSpec.describe ContactInboxWithContactBuilder do
  let(:channel) do
    ch = Channel::Whatsapp.new(
      provider: 'evolution_go',
      phone_number: "+1555#{SecureRandom.hex(3)}",
      provider_config: {}
    )
    ch.save!(validate: false)
    ch
  end

  let!(:inbox) { Inbox.create!(channel: channel, name: "Evo Go #{SecureRandom.hex(3)}") }

  def build(source_id, name: 'Ivone')
    described_class.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: { name: name, phone_number: '+553185298974' }
    ).perform
  end

  it 'reuses the ContactInbox stored with "+" when the same phone arrives without it' do
    first = build('+553185298974')

    expect { @again = build('553185298974') }.not_to change(ContactInbox, :count)
    expect(@again.id).to eq(first.id)
  end

  it 'stores a new phone source_id as digits only' do
    contact_inbox = build('+553185298974')

    expect(contact_inbox.source_id).to eq('553185298974')
  end

  it 'keeps a LID source_id untouched' do
    contact_inbox = build('80401804615788@lid', name: 'Ivone LID')

    expect(contact_inbox.source_id).to eq('80401804615788@lid')
  end
end
