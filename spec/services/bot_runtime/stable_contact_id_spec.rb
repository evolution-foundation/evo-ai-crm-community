# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::StableContactId do
  describe '.stable_contact_id' do
    it 'is deterministic for the same contact_id' do
      first = described_class.stable_contact_id('contact-1')
      second = described_class.stable_contact_id('contact-1')
      expect(first).to eq(second)
    end

    it 'differs for different contact_ids' do
      expect(described_class.stable_contact_id('contact-1'))
        .not_to eq(described_class.stable_contact_id('contact-2'))
    end

    it 'is always a positive int64' do
      value = described_class.stable_contact_id('contact-1')
      expect(value).to be_a(Integer)
      expect(value).to be >= 0
      expect(value).to be <= 0x7FFFFFFFFFFFFFFF
    end
  end
end
