# frozen_string_literal: true

require 'rails_helper'

# CRM-608: DEFAULT_LOCALE became the installation language, and this is the one consumer that
# does not treat it as a locale — it interpolates the value into an English prompt. Handed the
# raw code, the model reads "Please respond in pt_BR", and GlobalConfigService falls back to the
# environment here because DEFAULT_LOCALE is not a seeded installation_config.
RSpec.describe Integrations::OpenaiBaseService do
  around do |example|
    previous = ENV.fetch('DEFAULT_LOCALE', nil)
    example.run
  ensure
    previous.nil? ? ENV.delete('DEFAULT_LOCALE') : ENV['DEFAULT_LOCALE'] = previous
  end

  describe '.configured_language' do
    it 'names the language of an enabled locale instead of passing its code on' do
      ENV['DEFAULT_LOCALE'] = 'pt_BR'

      expect(described_class.configured_language).to eq('Brazilian Portuguese')
    end

    # A language enabled without a name here would hand the model its bare code again.
    it 'covers every locale the installation can be set to' do
      enabled = LANGUAGES_CONFIG.map { |_index, lang| lang[:iso_639_1_code] }

      expect(described_class::LANGUAGE_NAMES.keys).to match_array(enabled)
    end

    it 'keeps the english sentinel, so an en installation still gets the adaptive instruction' do
      ENV['DEFAULT_LOCALE'] = 'en'

      expect(described_class.configured_language).to eq('english')
    end

    it 'falls back to the sentinel when the installation sets no language' do
      ENV.delete('DEFAULT_LOCALE')

      expect(described_class.configured_language).to eq('english')
    end
  end

  describe 'the instruction the services actually send' do
    subject(:instruction) do
      Integrations::Openai::ProcessorService.new(hook: nil, event: {}).send(:language_instruction)
    end

    it 'asks for the installation language by name' do
      ENV['DEFAULT_LOCALE'] = 'pt_BR'

      expect(instruction).to eq(
        'Please respond in Brazilian Portuguese. If you\'re unsure about the language, ' \
        'use Brazilian Portuguese as the default.'
      )
      expect(instruction).not_to include('pt_BR')
    end

    it 'leaves the language to the conversation when the installation is on english' do
      ENV['DEFAULT_LOCALE'] = 'en'

      expect(instruction).to eq(Integrations::Openai::ProcessorService::LANGUAGE_INSTRUCTION)
    end
  end
end
