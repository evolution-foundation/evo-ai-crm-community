# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contact do
  # The number is the customer's datum: it is stored as informed. The WhatsApp
  # quirks (Brazilian ninth digit, MX/AR extra digit) are equivalences used to
  # FIND a contact and to address the channel, never a rewrite of what was typed.
  describe 'phone number storage' do
    { 'DDD 11' => '+5511988887777', 'DDD 31' => '+5531988887777', 'DDD 85' => '+5585988887777' }.each do |label, number|
      it "stores a Brazilian mobile as informed on create (#{label})" do
        contact = described_class.create!(name: label, phone_number: number, type: 'person')

        expect(contact.reload.phone_number).to eq(number)
      end
    end

    it 'stores the number as informed when it is edited' do
      contact = described_class.create!(name: 'Edited', email: 'edited@example.com', type: 'person')

      contact.update!(phone_number: '+5531988887777')

      expect(contact.reload.phone_number).to eq('+5531988887777')
    end

    it 'leaves a number already stored without the ninth digit alone' do
      contact = described_class.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')

      contact.update!(name: 'Legacy Renamed')

      expect(contact.reload.phone_number).to eq('+553188887777')
    end
  end

  describe 'phone number uniqueness across equivalent forms' do
    it 'refuses the ninth-digit form when the same number exists without it' do
      described_class.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')
      twin = described_class.new(name: 'Twin', phone_number: '+5531988887777', type: 'person')

      expect(twin).not_to be_valid
      expect(twin.errors[:phone_number]).to be_present
    end

    it 'refuses the form without the ninth digit when the same number exists with it' do
      described_class.create!(name: 'Full', phone_number: '+5531988887777', type: 'person')
      twin = described_class.new(name: 'Twin', phone_number: '+553188887777', type: 'person')

      expect(twin).not_to be_valid
    end

    it 'does not equate numbers the channel does not equate (DDD below 31)' do
      described_class.create!(name: 'Eight', phone_number: '+551188887777', type: 'person')

      expect(described_class.new(name: 'Nine', phone_number: '+5511988887777', type: 'person')).to be_valid
    end

    it 'lets a contact keep its own number on an unrelated edit' do
      contact = described_class.create!(name: 'Self', phone_number: '+5531988887777', type: 'person')

      expect(contact.update(name: 'Self Renamed')).to be(true)
    end
  end

  # A host may re-declare the uniqueness of the number under a scope. The check of
  # the equivalent forms follows whatever scope that validator carries.
  describe 'equivalent forms under a scoped uniqueness validator' do
    let(:scoped) do
      Class.new(described_class) do
        def self.name = 'Contact'
        validates :phone_number, uniqueness: { scope: :type }, allow_blank: true
      end
    end

    before { described_class.create!(name: 'Person', phone_number: '+553188887777', type: 'person') }

    it 'accepts the other form of the number outside the scope' do
      expect(scoped.new(name: 'Company', phone_number: '+5531988887777', type: 'company')).to be_valid
    end

    it 'still refuses it inside the scope' do
      expect(scoped.new(name: 'Twin', phone_number: '+5531988887777', type: 'person')).not_to be_valid
    end
  end

  describe '.from_phone_number' do
    it 'finds a contact stored with the ninth digit from the form the channel reports' do
      contact = described_class.create!(name: 'Full', phone_number: '+5531988887777', type: 'person')

      expect(described_class.from_phone_number('553188887777')).to eq(contact)
      expect(described_class.from_phone_number('553188887777@s.whatsapp.net')).to eq(contact)
    end

    it 'finds a contact stored without the ninth digit from the full form' do
      contact = described_class.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')

      expect(described_class.from_phone_number('+55 (31) 98888-7777')).to eq(contact)
    end

    it 'prefers the exact match when legacy twins of the same number exist' do
      legacy = described_class.create!(name: 'Legacy', phone_number: '+553188887777', type: 'person')
      full = described_class.create!(name: 'Full', email: 'full@example.com', type: 'person')
      # Written past the validation on purpose: the twin is what legacy data looks like.
      full.update_column(:phone_number, '+5531988887777') # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.from_phone_number('+5531988887777')).to eq(full)
      expect(described_class.from_phone_number('+553188887777')).to eq(legacy)
    end

    it 'is nil for a blank or unknown number' do
      expect(described_class.from_phone_number(nil)).to be_nil
      expect(described_class.from_phone_number('+5531977776666')).to be_nil
    end
  end
end
