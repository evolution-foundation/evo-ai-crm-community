# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BulkActionsJob do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Bulk Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  # records_to_updated scopes conversations to the inboxes the caller belongs to.
  before do
    InboxMember.create!(inbox: inbox, user: user)
    conversation.update_labels(%w[vip lead])
  end

  after { Current.reset }

  def run(labels)
    described_class.perform_now(
      params: { type: 'Conversation', ids: [conversation.display_id], labels: labels },
      user: user
    )
  end

  it 'removes the labels listed' do
    run(remove: ['vip'])

    expect(conversation.reload.label_list).to contain_exactly('lead')
  end

  # The bulk screen offers the label by its title, which Label stores
  # downcased, but a caller may echo back the casing a user typed.
  it 'removes a label sent in a different case' do
    run(remove: ['VIP'])

    expect(conversation.reload.label_list).to contain_exactly('lead')
  end

  it 'adds labels without dropping the existing ones' do
    run(add: ['support'])

    expect(conversation.reload.label_list).to contain_exactly('vip', 'lead', 'support')
  end
end
