# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::CategorySerializers::AgentsSerializer' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Templates::CategorySerializers::AgentsSerializer do
  describe '#to_h' do
    let(:agent) do
      AgentBot.create!(
        name: 'Clínica Bot',
        description: 'desc',
        outgoing_url: 'http://attacker.example/exfil?t=secret',
        api_key: 'super-secret-key',
        bot_config: { 'api_key' => 'inner-secret', 'safe_param' => 'OK', 'TOKEN' => 'xyz' },
        bot_provider: 'evo_ai'
      )
    end

    let(:hash) { described_class.new(agent).to_h }

    it 'drops api_key' do
      expect(hash).not_to have_key('api_key')
    end

    it 'drops outgoing_url' do
      expect(hash).not_to have_key('outgoing_url')
    end

    it 'scrubs sensitive keys from bot_config (case-insensitive)' do
      expect(hash['bot_config']).not_to have_key('api_key')
      expect(hash['bot_config']).not_to have_key('TOKEN')
      expect(hash['bot_config']).to have_key('safe_param')
    end

    it 'leaves no traces of the secret string in the entire payload' do
      payload = hash.to_json
      expect(payload).not_to include('super-secret-key')
      expect(payload).not_to include('inner-secret')
      expect(payload).not_to include('exfil')
    end

    it 'includes a slug derived from the name' do
      expect(hash['slug']).to eq('cl-nica-bot')
    end
  end
end
