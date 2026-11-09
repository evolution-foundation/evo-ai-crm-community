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

  describe 'contact actions' do
    let(:other) { Contact.create!(name: 'Other', email: "o-#{SecureRandom.hex(4)}@test.com") }

    before do
      contact.update_labels(%w[vip])
      contact.update!(custom_attributes: { 'plan' => 'gold', 'sector' => 'health' })
    end

    def run_contacts(fields)
      described_class.perform_now(params: { type: 'Contact', ids: [contact.id, other.id], fields: fields }, user: user)
    end

    it 'adds labels to every contact, keeping the ones they had' do
      result = run_contacts(action: 'add_labels', labels: ['lead'])

      expect(contact.reload.label_list).to contain_exactly('vip', 'lead')
      expect(other.reload.label_list).to contain_exactly('lead')
      expect(result[:success_ids]).to contain_exactly(contact.id, other.id)
    end

    it 'removes labels from every contact' do
      other.update_labels(%w[vip lead])

      run_contacts(action: 'remove_labels', labels: ['VIP'])

      expect(contact.reload.label_list).to be_empty
      expect(other.reload.label_list).to contain_exactly('lead')
    end

    it 'merges custom attributes into the ones each contact had' do
      run_contacts(action: 'update_custom_attributes', custom_attributes: { plan: 'silver', origin: 'bulk' })

      expect(contact.reload.custom_attributes).to eq('plan' => 'silver', 'sector' => 'health', 'origin' => 'bulk')
      expect(other.reload.custom_attributes).to eq('plan' => 'silver', 'origin' => 'bulk')
    end

    it 'resolves label ids to their titles, as the single-contact routes do' do
      label = Label.create!(title: 'partner', color: '#123456')

      run_contacts(action: 'add_labels', labels: [label.id])

      expect(other.reload.label_list).to contain_exactly('partner')
    end

    it 'still deletes when no action is given' do
      run_contacts({})

      expect(Contact.where(id: [contact.id, other.id])).to be_empty
    end
  end
end
