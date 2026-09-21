# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactIdentifyAction do
  let(:visitor) { Contact.create!(name: 'Visitor', type: 'person') }

  it 'recognises an existing contact from the other form of the same number' do
    existing = Contact.create!(name: 'Do canal', phone_number: '+553188887777', type: 'person')
    action = described_class.new(contact: visitor, params: { phone_number: '+5531988887777' })

    expect(action.send(:existing_phone_number_contact)).to eq(existing)
  end

  it 'is nil when no contact holds any form of the number' do
    action = described_class.new(contact: visitor, params: { phone_number: '+5531977776666' })

    expect(action.send(:existing_phone_number_contact)).to be_nil
  end
end
