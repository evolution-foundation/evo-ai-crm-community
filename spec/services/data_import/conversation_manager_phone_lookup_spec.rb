# frozen_string_literal: true

require 'rails_helper'

# The export carries the number in the form the channel reports; a contact created
# through another path keeps the number as informed. Own file so the lane runs it:
# conversation_manager_spec.rb is in no CI list.
RSpec.describe DataImport::ConversationManager do
  let(:data_import) { DataImport.create!(data_type: 'conversations') }

  def attach_csv(content)
    data_import.import_file.attach(
      io: StringIO.new(content),
      filename: 'conversations.csv',
      content_type: 'text/csv'
    )
  end

  def header_row
    'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id'
  end

  it 'matches a contact stored with the ninth digit from the form the channel exports' do
    full = Contact.create!(name: 'BH', phone_number: '+5531988887777', type: 'person')
    attach_csv([header_row, 'conv-bh,553188887777,Hi,incoming,2026-01-15T10:30:00Z,,text,msg-bh'].join("\n"))

    report = described_class.new(data_import).process

    expect(report['success_count']).to eq(1)
    expect(Conversation.find_by(identifier: 'conv-bh').contact_id).to eq(full.id)
  end

  it 'matches a contact stored without the ninth digit from the full form' do
    legacy = Contact.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')
    attach_csv([header_row, 'conv-legacy,5531988887777,Hi,incoming,2026-01-15T10:30:00Z,,text,msg-legacy'].join("\n"))

    report = described_class.new(data_import).process

    expect(report['success_count']).to eq(1)
    expect(Conversation.find_by(identifier: 'conv-legacy').contact_id).to eq(legacy.id)
  end
end
