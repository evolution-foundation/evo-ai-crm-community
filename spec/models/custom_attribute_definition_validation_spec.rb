# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomAttributeDefinition, type: :model do
  def build_definition(**attrs)
    described_class.new(
      {
        attribute_display_name: 'Plano',
        attribute_key: "plano_#{SecureRandom.hex(3)}",
        attribute_model: :contact_attribute,
        attribute_display_type: :text
      }.merge(attrs)
    )
  end

  describe 'list values' do
    it 'rejects a list without values' do
      [nil, [], ['', '  ']].each do |values|
        definition = build_definition(attribute_display_type: :list, attribute_values: values)

        expect(definition).not_to be_valid, "expected #{values.inspect} to be rejected"
        expect(definition.errors.details[:attribute_values]).to include(a_hash_including(error: :blank))
      end
    end

    it 'accepts a list with at least one value' do
      expect(build_definition(attribute_display_type: :list, attribute_values: %w[basico pro])).to be_valid
    end

    it 'does not ask other types for values' do
      expect(build_definition(attribute_display_type: :text, attribute_values: [])).to be_valid
    end

    it 'rejects turning an existing attribute into an empty list' do
      definition = build_definition
      definition.save!

      expect(definition.update(attribute_display_type: :list)).to be(false)
      expect(definition.errors.details[:attribute_values]).to include(a_hash_including(error: :blank))
    end
  end

  describe 'regex pattern' do
    it 'rejects a pattern that does not compile' do
      definition = build_definition(regex_pattern: '([a-z')

      expect(definition).not_to be_valid
      expect(definition.errors.details[:regex_pattern]).to include(a_hash_including(error: :invalid))
    end

    it 'accepts a pattern that compiles, and an empty one' do
      expect(build_definition(regex_pattern: '\A\d{5}-\d{3}\z')).to be_valid
      expect(build_definition(regex_pattern: '')).to be_valid
    end
  end

  describe 'a row saved before these rules' do
    let(:legacy) do
      build_definition.tap do |definition|
        definition.save!
        # rubocop:disable Rails/SkipsModelValidations -- simulates a row saved before the rules
        definition.update_columns(attribute_display_type: 6, attribute_values: [], regex_pattern: '([a-z')
        # rubocop:enable Rails/SkipsModelValidations
        definition.reload
      end
    end

    it 'can still have its other fields edited' do
      expect(legacy.update(attribute_display_name: 'Plano contratado')).to be(true)
    end

    it 'cannot be moved to another pattern that does not compile' do
      expect(legacy.update(regex_pattern: '(?<')).to be(false)
      expect(legacy.errors.details[:regex_pattern]).to include(a_hash_including(error: :invalid))
    end

    it 'cannot have its values replaced by an empty list' do
      expect(legacy.update(attribute_values: [''])).to be(false)
      expect(legacy.errors.details[:attribute_values]).to include(a_hash_including(error: :blank))
    end
  end
end
