# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Label, type: :model do
  describe 'color' do
    it 'accepts six- and three-digit hex colors' do
      expect(described_class.new(title: 'six', color: '#1F93ff')).to be_valid
      expect(described_class.new(title: 'three', color: '#abc')).to be_valid
    end

    it 'keeps the column default when no color is given' do
      expect(described_class.new(title: 'default')).to be_valid
    end

    it 'rejects a color that is not hex' do
      ['red', '#12345', '#ffff', '#ggg', '1f93ff', ''].each do |color|
        label = described_class.new(title: 'vip', color: color)

        expect(label).not_to be_valid, "expected #{color.inspect} to be rejected"
        expect(label.errors.details[:color]).to be_present
      end
    end

    it 'rejects a nil color before it reaches the NOT NULL column' do
      label = described_class.new(title: 'vip', color: nil)

      expect(label).not_to be_valid
      expect(label.errors.details[:color]).to include(a_hash_including(error: :blank))
    end

    it 'renders a translated message instead of a missing-translation marker' do
      label = described_class.new(title: 'vip', color: 'red')
      label.valid?

      expect(label.errors[:color].join).not_to include('Translation missing')
    end

    # The :en fallback would hide a missing pt_BR entry behind an English sentence.
    it 'has its own pt_BR message' do
      I18n.with_locale(:pt_BR) do
        label = described_class.new(title: 'vip', color: 'red')
        label.valid?

        expect(label.errors[:color]).to eq(['deve ser uma cor hexadecimal válida'])
      end
    end
  end

  describe 'title length' do
    it 'rejects a single character, counted after the spaces are stripped' do
      label = described_class.new(title: ' a ', color: '#1f93ff')

      expect(label).not_to be_valid
      expect(label.errors.details[:title]).to include(a_hash_including(error: :too_short))
    end

    it 'accepts two characters' do
      expect(described_class.new(title: 'ab', color: '#1f93ff')).to be_valid
    end
  end

  describe 'a row saved before these rules' do
    let(:legacy) do
      described_class.create!(title: 'legacy', color: '#1f93ff').tap do |label|
        label.update_columns(title: 'x', color: 'red') # rubocop:disable Rails/SkipsModelValidations -- simulates a row saved before the rules
        label.reload
      end
    end

    it 'can still have its other fields edited' do
      expect(legacy.update(description: 'still editable')).to be(true)
    end

    it 'cannot be moved to another invalid color' do
      expect(legacy.update(color: 'blue')).to be(false)
      expect(legacy.errors.details[:color]).to be_present
    end

    it 'cannot be renamed to another one-character title' do
      expect(legacy.update(title: 'y')).to be(false)
      expect(legacy.errors.details[:title]).to include(a_hash_including(error: :too_short))
    end
  end
end
