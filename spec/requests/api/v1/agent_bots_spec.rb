require 'rails_helper'

RSpec.describe 'Api::V1::AgentBots', type: :request do
  describe 'POST /api/v1/agent_bots' do
    context 'with evo_ai_provider' do
      before { stub_auth }
      it 'creates an agent bot with api_key successfully' do
        post '/api/v1/agent_bots', params: {
          name: 'Support Agent',
          description: 'A test support agent',
          outgoing_url: 'http://localhost:5000/support',
          bot_type: 'webhook',
          bot_provider: 'evo_ai',
          api_key: 'secret_key'
        }, as: :json

        expect(response).to have_http_status(:created)
        
        json_response = JSON.parse(response.body)
        expect(json_response['message']).to eq('Agent bot created successfully')
        
        bot = AgentBot.last
        expect(bot.api_key).to eq('secret_key')
        expect(bot.credential_id).to be_nil
      end

      it 'creates an agent bot with credential_id successfully' do
        uuid = SecureRandom.uuid
        post '/api/v1/agent_bots', params: {
          name: 'Support Agent',
          description: 'A test support agent',
          outgoing_url: 'http://localhost:5000/support',
          bot_type: 'webhook',
          bot_provider: 'evo_ai',
          credential_id: uuid
        }, as: :json

        expect(response).to have_http_status(:created)
        
        bot = AgentBot.last
        expect(bot.api_key).to be_nil
        expect(bot.credential_id).to eq(uuid)
      end
    end
  end
end
