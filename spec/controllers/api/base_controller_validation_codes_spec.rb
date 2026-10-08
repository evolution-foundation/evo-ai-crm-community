# frozen_string_literal: true

require 'rails_helper'

# `codes` is what clients translate. An error added as a string is a sentence in the
# installation locale, so it must never be emitted as a code.
RSpec.describe Api::BaseController do
  it 'emits only symbol error types as codes' do
    errors = Label.new.errors
    errors.add(:title, :taken)
    errors.add(:title, 'texto livre do model')
    errors.add(:color, 'outra frase')

    details = described_class.new.send(:format_validation_errors, errors)

    expect(details).to contain_exactly(
      a_hash_including(field: :title, codes: ['taken']),
      a_hash_including(field: :color, codes: [])
    )
    expect(details.find { |detail| detail[:field] == :title }[:messages]).to include('texto livre do model')
  end
end
