# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ConversationFinder do
  describe 'current assignee filtering' do
    let(:user) { User.create!(name: 'Agent A', email: "a-#{SecureRandom.hex(4)}@example.test") }
    let(:other_user) { User.create!(name: 'Agent B', email: "b-#{SecureRandom.hex(4)}@example.test") }
    let(:inbox) { Inbox.create!(name: 'Accessible', channel: Channel::Api.create!, enable_auto_assignment: false) }
    let(:other_inbox) { Inbox.create!(name: 'Inaccessible', channel: Channel::Api.create!, enable_auto_assignment: false) }
    let(:contact) { Contact.create!(name: 'Contact') }
    let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
    let!(:open_conversation) { make_conversation(assignee: user, status: :open) }
    let!(:resolved_conversation) { make_conversation(assignee: user, status: :resolved) }
    let!(:other_conversation) { make_conversation(assignee: other_user, status: :open) }
    let!(:unassigned_conversation) { make_conversation(assignee: nil, status: :open) }

    before do
      allow(user).to receive(:administrator?).and_return(false)
      allow(user).to receive(:assigned_inboxes).and_return(Inbox.where(id: inbox.id))
    end

    def make_conversation(attributes)
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, **attributes)
    end

    def find_conversations(params = {})
      described_class.new(user, { status: 'all', **params }).perform
    end

    it 'filters both the list and counts by the selected current assignee' do
      result = find_conversations(assignee_id: user.id)

      expect(result[:conversations].map(&:id)).to contain_exactly(open_conversation.id, resolved_conversation.id)
      expect(result[:count]).to eq(mine_count: 2, assigned_count: 2, unassigned_count: 0, all_count: 2)
    end

    it 'supports another assignee without including the current user' do
      result = find_conversations(assignee_id: other_user.id)

      expect(result[:conversations].map(&:id)).to eq([other_conversation.id])
      expect(result[:count]).to eq(mine_count: 0, assigned_count: 1, unassigned_count: 0, all_count: 1)
    end

    it 'uses OR between selected users and excludes unassigned conversations' do
      result = find_conversations(assignee_id: [user.id, other_user.id])

      expect(result[:conversations].map(&:id)).to contain_exactly(open_conversation.id, resolved_conversation.id, other_conversation.id)
      expect(result[:count][:all_count]).to eq(3)
    end

    it 'accepts comma-separated IDs, whitespace, empty entries and duplicates' do
      result = find_conversations(assignee_id: [" #{user.id},#{other_user.id}, ", user.id])

      expect(result[:conversations].map(&:id)).to contain_exactly(open_conversation.id, resolved_conversation.id, other_conversation.id)
      expect(result[:count][:all_count]).to eq(3)
    end

    it 'intersects the assignee with the status filter' do
      result = find_conversations(assignee_id: [user.id, other_user.id], status: 'resolved')

      expect(result[:conversations].map(&:id)).to eq([resolved_conversation.id])
      expect(result[:count][:all_count]).to eq(1)
    end

    it 'restores the remaining status criterion when assignee selection is empty' do
      result = find_conversations(assignee_id: ['', ' '], status: 'open')

      expect(result[:conversations].map(&:id)).to contain_exactly(open_conversation.id, other_conversation.id, unassigned_conversation.id)
      expect(result[:count][:all_count]).to eq(3)
    end

    it 'keeps counts constant across filtered pages and returns each matching ID once' do
      pages = (1..2).map { |page| find_conversations(assignee_id: user.id, page: page, per_page: 1) }

      expect(pages.flat_map { |result| result[:conversations].map(&:id) }).to contain_exactly(open_conversation.id, resolved_conversation.id)
      expect(pages.map { |result| result[:count][:all_count] }).to eq([2, 2])
      expect(find_conversations(assignee_id: user.id, page: 3, per_page: 1)[:conversations]).to be_empty
    end

    it 'does not include inaccessible inboxes even when their current assignee matches' do
      inaccessible_contact_inbox = ContactInbox.create!(contact: contact, inbox: other_inbox, source_id: SecureRandom.hex(8))
      Conversation.create!(inbox: other_inbox, contact: contact, contact_inbox: inaccessible_contact_inbox, assignee: user)

      result = find_conversations(assignee_id: user.id)

      expect(result[:conversations].map(&:id)).to contain_exactly(open_conversation.id, resolved_conversation.id)
      expect(result[:count][:all_count]).to eq(2)
    end

    it 'does not confuse message authors or historical assignees with current assignment' do
      open_conversation.update!(assignee: other_user)
      Message.create!(conversation: other_conversation, inbox: inbox, sender: user, content: 'Earlier reply', message_type: :outgoing)

      result = find_conversations(assignee_id: user.id)

      expect(result[:conversations].map(&:id)).to eq([resolved_conversation.id])
      expect(result[:count][:all_count]).to eq(1)
    end

    it 'returns an empty list and zero counts for an unknown UUID' do
      result = find_conversations(assignee_id: SecureRandom.uuid)

      expect(result[:conversations]).to be_empty
      expect(result[:count][:all_count]).to eq(0)
    end

    it 'preserves the anonymous-user empty result' do
      result = described_class.new(nil, { status: 'all', assignee_id: user.id }).perform

      expect(result[:conversations]).to be_empty
      expect(result[:count][:all_count]).to eq(0)
    end

    it 'applies the predicate directly to conversations.assignee_id' do
      sql = described_class.new(user, { status: 'all', assignee_id: user.id }).send(:build_base_filter_query).to_sql

      expect(sql).to include('"conversations"."assignee_id"')
      expect(sql).not_to include('JOIN "messages"')
    end
  end
end
