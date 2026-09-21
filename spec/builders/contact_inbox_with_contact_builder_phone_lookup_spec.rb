# frozen_string_literal: true

require 'rails_helper'

# The channel reports a number in the form WhatsApp resolves it to; a contact
# created through another path keeps the number as informed.
RSpec.describe ContactInboxWithContactBuilder do
  subject(:builder) { described_class.allocate }

  it 'matches the inbound channel form to a contact stored with the ninth digit' do
    contact = Contact.create!(name: 'Da API', phone_number: '+5531988887777', type: 'person')

    expect(builder.send(:find_contact_by_phone_number, '+553188887777')).to eq(contact)
  end

  it 'matches the full form to a contact the channel created without the ninth digit' do
    contact = Contact.create!(name: 'Do canal', phone_number: '+553188887777', type: 'person')

    expect(builder.send(:find_contact_by_phone_number, '+5531988887777')).to eq(contact)
  end

  it 'is nil for a blank number' do
    expect(builder.send(:find_contact_by_phone_number, nil)).to be_nil
  end
end
