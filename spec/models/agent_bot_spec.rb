require 'rails_helper'

RSpec.describe AgentBot, type: :model do
  describe 'validations' do
    context 'when bot_provider is evo_ai_provider' do
      it 'is valid with only api_key' do
        bot = AgentBot.new(name: 'Test', outgoing_url: 'http://test', bot_provider: 'evo_ai', api_key: 'test_key', credential_id: nil)
        expect(bot).to be_valid
      end

      it 'is valid with only credential_id' do
        bot = AgentBot.new(name: 'Test', outgoing_url: 'http://test', bot_provider: 'evo_ai', api_key: nil, credential_id: SecureRandom.uuid)
        expect(bot).to be_valid
      end

      it 'is invalid without api_key and credential_id' do
        bot = AgentBot.new(name: 'Test', outgoing_url: 'http://test', bot_provider: 'evo_ai', api_key: nil, credential_id: nil)
        expect(bot).not_to be_valid
        expect(bot.errors[:api_key]).to include("can't be blank")
        expect(bot.errors[:credential_id]).to include("can't be blank")
      end
    end
  end
end
