# frozen_string_literal: true

require 'rails_helper'

# This service repairs the customer's own label data, so it is exercised rather
# than read: every example runs it and asserts on the rows it leaves behind.
RSpec.describe Labels::OrphanReconcileService do
  let(:io) { StringIO.new }
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Inbox', channel: channel) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def run(fix: false, purge: false)
    described_class.call(fix: fix, purge: purge, io: io)
    io.string
  end

  # Applies a label the way the legacy rows were written: straight onto the
  # tagging table, with the cached column reflecting that raw name.
  def apply_raw(taggable, name)
    tag = ActsAsTaggableOn::Tag.find_or_create_by!(name: name)
    ActsAsTaggableOn::Tagging.find_or_create_by!(tag: tag, taggable: taggable, context: 'labels')
    if taggable.class.column_names.include?('cached_label_list')
      taggable.update_column(:cached_label_list, taggable.labels.reload.map(&:name).join(', ')) # rubocop:disable Rails/SkipsModelValidations
    end
    tag
  end

  describe 'the report' do
    it 'reports nothing to do on a clean catalog' do
      expect(run).to include('every label tagging matches a catalog entry')
    end

    it 'states what the scope holds, so an empty one is never read as a clean one' do
      Label.create!(title: 'urgente')
      apply_raw(contact, 'urgente')

      expect(run).to include('visible here: 1 catalog entries, 1 tags, 1 applications')
    end

    it 'says so when the scope holds no label rows at all' do
      expect(run).to include('this scope holds no label rows at all')
    end

    it 'reports each family without touching anything in dry-run' do
      Label.create!(title: 'urgente')
      apply_raw(contact, 'Urgente')
      apply_raw(contact, 'sem catalogo')
      apply_raw(contact, '11111111-2222-3333-4444-555555555555')

      output = run
      expect(output).to match(/case.*Urgente/)
      expect(output).to match(/missing.*sem catalogo/)
      expect(output).to match(/uuid.*1111/)
      expect(ActsAsTaggableOn::Tag.where(name: 'Urgente')).to exist
      expect(Label.where(title: 'sem catalogo')).not_to exist
    end
  end

  describe 'the case family' do
    it 'rewires a case-divergent tag onto the catalog one' do
      Label.create!(title: 'urgente')
      bad = apply_raw(contact, 'Urgente')

      run(fix: true)

      expect(ActsAsTaggableOn::Tag.where(id: bad.id)).not_to exist
      expect(contact.reload.label_list.to_a).to eq(['urgente'])
    end
  end

  describe 'the missing family' do
    it 'catalogs the title and rewires the tag in a single run' do
      apply_raw(contact, 'Cliente VIP')

      run(fix: true)

      expect(Label.where(title: 'cliente vip')).to exist
      # Without the rewire the tag stays "Cliente VIP", which the exact filter
      # never matches: the label would be catalogued and still invisible.
      expect(contact.reload.label_list.to_a).to eq(['cliente vip'])
      expect(ActsAsTaggableOn::Tag.where(name: 'Cliente VIP')).not_to exist
    end

    it 'has nothing left to do on a second run, which is what idempotent means' do
      apply_raw(contact, 'Cliente VIP')
      run(fix: true)

      io.truncate(0)
      io.rewind
      expect(run(fix: true)).to include('every label tagging matches a catalog entry')
    end

    it 'deletes the applications instead, with purge' do
      apply_raw(contact, 'sem catalogo')

      run(fix: true, purge: true)

      expect(contact.reload.label_list.to_a).to be_empty
      expect(Label.where(title: 'sem catalogo')).not_to exist
    end
  end

  describe 'the uuid family' do
    it 'only reports it, even with fix and purge' do
      uuid = '11111111-2222-3333-4444-555555555555'
      apply_raw(contact, uuid)

      expect(run(fix: true, purge: true)).to match(/uuid/)
      expect(contact.reload.label_list.to_a).to eq([uuid])
      expect(Label.where(title: uuid)).not_to exist
    end
  end

  # A conversation serves its labels from `cached_label_list`, so a tagging
  # moved or deleted by SQL alone leaves the screen showing the old value.
  describe 'the conversation cache' do
    it 'shows the canonical title after a rewire' do
      Label.create!(title: 'urgente')
      apply_raw(conversation, 'Urgente')
      expect(conversation.reload.label_list.to_a).to eq(['Urgente'])

      run(fix: true)

      expect(conversation.reload.label_list.to_a).to eq(['urgente'])
      expect(conversation.reload.cached_label_list).to eq('urgente')
    end

    it 'stays empty after a purge, instead of coming back on the next write' do
      apply_raw(conversation, 'lixo')

      run(fix: true, purge: true)

      expect(conversation.reload.label_list.to_a).to be_empty

      conversation.reload.add_labels(['nova'])
      expect(conversation.reload.label_list.to_a).to eq(['nova'])
    end
  end

  # Product labels are free text per product and share no catalog with contacts
  # and conversations.
  describe 'products' do
    let(:product) { Product.create!(name: 'Base', kind: 'physical', default_price: 10, currency: 'BRL') }

    it 'leaves a product tagging alone' do
      tag = apply_raw(product, 'Promoção de Verão')

      run(fix: true, purge: true)

      expect(ActsAsTaggableOn::Tag.where(id: tag.id)).to exist
      expect(product.reload.label_list.to_a).to eq(['Promoção de Verão'])
      expect(Label.where(title: 'promoção de verão')).not_to exist
    end

    it 'keeps a tag a product shares with a contact, deleting only the contact side' do
      tag = apply_raw(product, 'Promoção de Verão')
      apply_raw(contact, 'Promoção de Verão')

      run(fix: true, purge: true)

      expect(ActsAsTaggableOn::Tag.where(id: tag.id)).to exist
      expect(product.reload.label_list.to_a).to eq(['Promoção de Verão'])
      expect(contact.reload.label_list.to_a).to be_empty
    end
  end
end
