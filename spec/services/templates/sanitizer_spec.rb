# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::Sanitizer' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

require_relative '../../../app/services/templates/sanitizer'

RSpec.describe Templates::Sanitizer do
  describe '.scrub_macro_actions' do
    it 'nullifies action_params on send_webhook_event' do
      actions = [
        { 'action_name' => 'send_message', 'action_params' => ['hello'] },
        { 'action_name' => 'send_webhook_event', 'action_params' => { 'url' => 'http://evil' } }
      ]
      result = described_class.scrub_macro_actions(actions)
      expect(result[0]['action_params']).to eq(['hello'])
      expect(result[1]['action_params']).to be_nil
    end

    it 'returns empty array on non-array input' do
      expect(described_class.scrub_macro_actions(nil)).to eq([])
      expect(described_class.scrub_macro_actions('foo')).to eq([])
    end
  end

  describe '.scrub_whatsapp_provider_config' do
    it 'removes known secret keys' do
      config = { 'api_key' => 'X', 'waba_id' => 'Y', 'safe_key' => 'OK' }
      result = described_class.scrub_whatsapp_provider_config(config)
      expect(result).to eq('safe_key' => 'OK')
    end

    it 'returns {} on non-hash input' do
      expect(described_class.scrub_whatsapp_provider_config(nil)).to eq({})
    end
  end

  describe '.scrub_email_provider_config' do
    it 'removes OAuth tokens' do
      config = { 'access_token' => 'A', 'refresh_token' => 'R', 'inbox_name' => 'support' }
      result = described_class.scrub_email_provider_config(config)
      expect(result).to eq('inbox_name' => 'support')
    end
  end

  describe '.zero_blocked_fields!' do
    it 'nils blocked fields for agents category' do
      attrs = { 'outgoing_url' => 'http://evil', 'api_key' => 'secret', 'name' => 'kept' }
      described_class.zero_blocked_fields!('agents', attrs)
      expect(attrs['outgoing_url']).to be_nil
      expect(attrs['api_key']).to be_nil
      expect(attrs['name']).to eq('kept')
    end

    it 'is a no-op for unknown categories' do
      attrs = { 'foo' => 'bar' }
      described_class.zero_blocked_fields!('unknown', attrs)
      expect(attrs).to eq('foo' => 'bar')
    end
  end
end
