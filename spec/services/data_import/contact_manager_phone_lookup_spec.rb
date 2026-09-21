# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataImport::ContactManager do
  subject(:manager) { described_class.new }

  it 'matches an imported row to a contact stored in the other form of the number' do
    existing = Contact.create!(name: 'Do canal', phone_number: '+553188887777', type: 'person')

    expect(manager.send(:find_contact_by_phone_number, { phone_number: '55 (31) 98888-7777' })).to eq(existing)
  end

  it 'matches the channel form to a contact stored with the ninth digit' do
    existing = Contact.create!(name: 'Da API', phone_number: '+5531988887777', type: 'person')

    expect(manager.send(:find_contact_by_phone_number, { phone_number: '553188887777' })).to eq(existing)
  end
end
