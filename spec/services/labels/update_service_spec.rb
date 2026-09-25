# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

# B1: regression guard for Labels::UpdateService.
#
# Pre-fix, the rename did `contact.label_list.remove(old) + .add(new) + save!`
# which mutates the TagList in place without dirty-tracking `label_list`, so
# `Contact#publish_label_changes` returned early — silently breaking AC3/AC4
# for the rename path.
#
# Post-fix the service routes through `update!(label_list: ...)`, so the
# commit hook diffs the change and fires `:contact_label_added/removed`.
RSpec.describe Labels::UpdateService do
  # The EvoFlow listener is globally subscribed and would otherwise enqueue
  # against a real Sidekiq client (and try to reach Redis on CI) when these
  # specs emit `:contact_label_*`. `fake!` keeps the test self-contained.
  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  let(:contact) { Contact.create!(name: 'Hue', email: "hue-#{SecureRandom.hex(4)}@test.com") }

  it 'emits :contact_label_removed for the old name and :contact_label_added for the new name' do
    contact.update!(label_list: ['old-name'])

    # The service iterates `tagged_contacts.find_in_batches`, so the in-memory
    # contact it mutates is NOT the `contact` let. Subscribe globally instead.
    added = []
    removed = []
    listener = Class.new do
      define_method(:contact_label_added)   { |data| added   << data[:data] }
      define_method(:contact_label_removed) { |data| removed << data[:data] }
    end.new
    Wisper.subscribe(listener) do
      described_class.new(new_label_title: 'new-name', old_label_title: 'old-name').perform
    end

    expect(added.map { |d| d[:label_name] }).to include('new-name')
    expect(removed.map { |d| d[:label_name] }).to include('old-name')
    expect(contact.reload.label_list).to contain_exactly('new-name')
  end

  # L-2: rename of a contact that already carries both
  # old and new titles should drop the old one without emitting a spurious
  # add for the already-present new title.
  it 'does not emit :contact_label_added when the new name is already in the list' do
    contact.update!(label_list: %w[old-name new-name])

    added = []
    removed = []
    listener = Class.new do
      define_method(:contact_label_added)   { |data| added   << data[:data] }
      define_method(:contact_label_removed) { |data| removed << data[:data] }
    end.new
    Wisper.subscribe(listener) do
      described_class.new(new_label_title: 'new-name', old_label_title: 'old-name').perform
    end

    expect(removed.map { |d| d[:label_name] }).to include('old-name')
    expect(added.map { |d| d[:label_name] }).not_to include('new-name')
    expect(contact.reload.label_list).to contain_exactly('new-name')
  end

  # M-3: a no-op rename (`old == new`) must short-circuit
  # the service so neither the remove nor the add is published.
  it 'is a no-op when old and new titles are identical' do
    contact.update!(label_list: ['same'])

    added = []
    removed = []
    listener = Class.new do
      define_method(:contact_label_added)   { |data| added   << data[:data] }
      define_method(:contact_label_removed) { |data| removed << data[:data] }
    end.new
    Wisper.subscribe(listener) do
      described_class.new(new_label_title: 'same', old_label_title: 'same').perform
    end

    expect(added).to be_empty
    expect(removed).to be_empty
    expect(contact.reload.label_list).to contain_exactly('same')
  end

  # The rename finds its rows with `tagged_with`, which matches ignoring case,
  # while the subtraction used to be exact: a label stored as "Urgente" was
  # located and then left in place, so the old title outlived its catalog entry.
  describe 'a title applied with different casing' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    def apply_raw(taggable, name)
      tag = ActsAsTaggableOn::Tag.find_or_create_by!(name: name)
      ActsAsTaggableOn::Tagging.find_or_create_by!(tag: tag, taggable: taggable, context: 'labels')
      return unless taggable.class.column_names.include?('cached_label_list')

      taggable.update_column(:cached_label_list, name) # rubocop:disable Rails/SkipsModelValidations
    end

    it 'is replaced on a contact, not left behind' do
      apply_raw(contact, 'Urgente')

      described_class.new(new_label_title: 'critico', old_label_title: 'urgente').perform

      expect(contact.reload.label_list.to_a).to eq(['critico'])
    end

    it 'is replaced on a conversation, not left behind' do
      apply_raw(conversation, 'Urgente')

      described_class.new(new_label_title: 'critico', old_label_title: 'urgente').perform

      expect(conversation.reload.label_list.to_a).to eq(['critico'])
    end

    # Renaming must not start emitting a conversation update per conversation:
    # that reaches webhooks, automations and evo-flow, and the rename never did.
    it 'does not dispatch a conversation update per conversation' do
      apply_raw(conversation, 'Urgente')
      dispatched = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) { |name, *_| dispatched << name }

      described_class.new(new_label_title: 'critico', old_label_title: 'urgente').perform

      expect(dispatched).not_to include(Conversation::CONVERSATION_UPDATED)
    end
  end
end
