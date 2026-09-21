# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contact, type: :model do
  let(:person_contact)  { Contact.create!(name: 'Alice', email: 'alice@example.com', type: 'person') }
  let(:company_contact) { Contact.create!(name: 'Acme Corp', type: 'company') }
  let(:group_contact)   { Contact.create!(name: 'Almoço BH', identifier: '12345-9876@g.us', type: 'group') }

  describe '#group?' do
    it 'returns true for type=group' do
      expect(group_contact.group?).to be true
    end

    it 'returns false for type=person' do
      expect(person_contact.group?).to be false
    end

    it 'returns false for type=company' do
      expect(company_contact.group?).to be false
    end
  end

  describe '.non_groups scope' do
    before { person_contact; company_contact; group_contact }

    it 'excludes contacts with type=group' do
      ids = Contact.non_groups.pluck(:id)
      expect(ids).not_to include(group_contact.id)
    end

    it 'includes person and company contacts' do
      ids = Contact.non_groups.pluck(:id)
      expect(ids).to include(person_contact.id, company_contact.id)
    end
  end

  describe '#assign_to_default_pipeline' do
    let!(:pipeline) { Pipeline.create!(name: 'Default', pipeline_type: 'sales', is_default: true, created_by: User.create!(email: 'dev@example.com', name: 'Dev')) }

    it 'skips pipeline assignment for group contacts' do
      expect { group_contact }.not_to change(PipelineItem, :count)
    end

    it 'creates a pipeline item for person contacts when a default pipeline exists' do
      expect { person_contact }.to change(PipelineItem, :count).by(1)
    end
  end

  # H2 + M3: publishers for custom_attribute and label changes were
  # previously orphaned (never called in production). These specs exercise
  # the real model write path so a regression would surface immediately.
  describe 'Wisper publishers (H2)' do
    let(:contact) { Contact.create!(name: 'Hue', email: 'hue@example.com', type: 'person') }

    it 'emits :contact_custom_attribute_changed for each changed key' do
      collected = []
      listener = Class.new do
        define_method(:contact_custom_attribute_changed) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      contact.update!(custom_attributes: { 'tier' => 'gold', 'plan' => 'pro' })

      events = collected.map { |d| [d[:attribute_name], d[:change_type], d[:attribute_value]] }
      expect(events).to include(['tier', 'added', 'gold'], ['plan', 'added', 'pro'])
    end

    it 'emits :contact_label_added when a new label is applied via update_labels' do
      collected = []
      listener = Class.new do
        define_method(:contact_label_added) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      contact.update_labels(['vip'])

      expect(collected.map { |d| d[:label_name] }).to include('vip')
    end

    it 'emits :contact_label_removed when an existing label is dropped via update_labels' do
      contact.update_labels(['vip', 'beta'])
      collected = []
      listener = Class.new do
        define_method(:contact_label_removed) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      contact.update_labels(['vip'])

      expect(collected.map { |d| d[:label_name] }).to include('beta')
    end

    # B1: the production automation/rename paths reach
    # `Contact#publish_label_changes` only when the write goes through the
    # setter (`label_list = ...`), which dirty-tracks the attribute. These
    # specs guard against a regression where any of those paths bypass
    # the commit hook.
    it 'emits :contact_label_added via update(label_list:) setter (controller path)' do
      collected = []
      listener = Class.new do
        define_method(:contact_label_added) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      contact.update!(label_list: ['vip'])

      expect(collected.map { |d| d[:label_name] }).to include('vip')
    end

    it 'emits :contact_label_removed via update(label_list:) setter (controller path)' do
      contact.update!(label_list: %w[vip beta])
      collected = []
      listener = Class.new do
        define_method(:contact_label_removed) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      contact.update!(label_list: ['vip'])

      expect(collected.map { |d| d[:label_name] }).to include('beta')
    end
  end

  # The number is the customer's datum: it is stored as informed. The WhatsApp
  # quirks (Brazilian ninth digit, MX/AR extra digit) are equivalences used to
  # FIND a contact and to address the channel, never a rewrite of what was typed.
  describe 'phone number storage' do
    { 'DDD 11' => '+5511988887777', 'DDD 31' => '+5531988887777', 'DDD 85' => '+5585988887777' }.each do |label, number|
      it "stores a Brazilian mobile as informed on create (#{label})" do
        contact = Contact.create!(name: label, phone_number: number, type: 'person')

        expect(contact.reload.phone_number).to eq(number)
      end
    end

    it 'stores the number as informed when it is edited' do
      contact = Contact.create!(name: 'Edited', email: 'edited@example.com', type: 'person')

      contact.update!(phone_number: '+5531988887777')

      expect(contact.reload.phone_number).to eq('+5531988887777')
    end

    it 'leaves a number already stored without the ninth digit alone' do
      contact = Contact.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')

      contact.update!(name: 'Legacy Renamed')

      expect(contact.reload.phone_number).to eq('+553188887777')
    end
  end

  describe 'phone number uniqueness across equivalent forms' do
    it 'refuses the ninth-digit form when the same number exists without it' do
      Contact.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')
      twin = Contact.new(name: 'Twin', phone_number: '+5531988887777', type: 'person')

      expect(twin).not_to be_valid
      expect(twin.errors[:phone_number]).to be_present
    end

    it 'refuses the form without the ninth digit when the same number exists with it' do
      Contact.create!(name: 'Full', phone_number: '+5531988887777', type: 'person')
      twin = Contact.new(name: 'Twin', phone_number: '+553188887777', type: 'person')

      expect(twin).not_to be_valid
    end

    it 'does not equate numbers the channel does not equate (DDD below 31)' do
      Contact.create!(name: 'Eight', phone_number: '+551188887777', type: 'person')

      expect(Contact.new(name: 'Nine', phone_number: '+5511988887777', type: 'person')).to be_valid
    end

    it 'lets a contact keep its own number on an unrelated edit' do
      contact = Contact.create!(name: 'Self', phone_number: '+5531988887777', type: 'person')

      expect(contact.update(name: 'Self Renamed')).to be(true)
    end
  end

  describe '.from_phone_number' do
    it 'finds a contact stored with the ninth digit from the form the channel reports' do
      contact = Contact.create!(name: 'Full', phone_number: '+5531988887777', type: 'person')

      expect(Contact.from_phone_number('553188887777')).to eq(contact)
      expect(Contact.from_phone_number('553188887777@s.whatsapp.net')).to eq(contact)
    end

    it 'finds a contact stored without the ninth digit from the full form' do
      contact = Contact.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')

      expect(Contact.from_phone_number('+55 (31) 98888-7777')).to eq(contact)
    end

    it 'prefers the exact match when legacy twins of the same number exist' do
      legacy = Contact.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')
      full = Contact.create!(name: 'Full', email: 'full@example.com', type: 'person')
      full.update_column(:phone_number, '+5531988887777')

      expect(Contact.from_phone_number('+5531988887777')).to eq(full)
      expect(Contact.from_phone_number('+553188887777')).to eq(legacy)
    end

    it 'is nil for a blank or unknown number' do
      expect(Contact.from_phone_number(nil)).to be_nil
      expect(Contact.from_phone_number('+5531977776666')).to be_nil
    end
  end
end
