# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::OpenaiBaseService do
  subject(:service) { described_class.new(hook: double('hook'), event: 'fix_spelling_grammar') }

  describe '#account_language' do
    it 'defaults to pt-BR when no DEFAULT_LOCALE is configured' do
      allow(GlobalConfigService).to receive(:load).with('DEFAULT_LOCALE', 'pt-BR').and_call_original

      expect(service.send(:account_language)).to eq('pt-BR')
    end

    it 'uses the configured DEFAULT_LOCALE when present' do
      allow(GlobalConfigService).to receive(:load).with('DEFAULT_LOCALE', 'pt-BR').and_return('es')

      expect(service.send(:account_language)).to eq('es')
    end
  end

  describe '#language_instruction' do
    it 'instructs the model to reply in the account language and never translate' do
      allow(GlobalConfigService).to receive(:load).with('DEFAULT_LOCALE', 'pt-BR').and_return('pt-BR')

      instruction = service.send(:language_instruction)

      expect(instruction).to include('pt-BR')
      expect(instruction).to include('Never translate')
    end
  end

  describe '#get_prompt' do
    it 'embeds the language instruction in the fix_spelling_grammar prompt' do
      allow(GlobalConfigService).to receive(:load).with('DEFAULT_LOCALE', 'pt-BR').and_return('pt-BR')
      allow(GlobalConfigService).to receive(:load).with('OPENAI_PROMPT_FIX_GRAMMAR', anything).and_call_original

      prompt = service.send(:get_prompt, 'fix_spelling_grammar')

      expect(prompt).to include('Always reply in pt-BR')
    end
  end
end
