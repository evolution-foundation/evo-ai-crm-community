require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::AiAgents::KnowledgeBases', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:user) { User.create!(name: 'Agent Knowledge Test User', email: "agent-knowledge-#{SecureRandom.hex(4)}@example.com") }
  let(:knowledge_base) { create(:knowledge_base) }
  let(:ai_agent_id) { SecureRandom.uuid }

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  before do
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true, data: { user: { id: user.id, email: user.email, role: { id: 1, key: 'test_role', name: 'test_role' } } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: %w[ai_agents.read ai_agents.update].include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
    allow(EvoAiCoreService).to receive(:get_agent).and_return(
      { 'name' => 'Bot', 'type' => 'llm', 'config' => {} }
    )
    allow(EvoAiCoreService).to receive(:update_agent)
  end

  it 'attaches a knowledge base to an agent' do
    post "/api/v1/ai_agents/#{ai_agent_id}/knowledge_base",
         params: { knowledge_base_id: knowledge_base.id, knowledge_tags: ['vendas'] }.to_json,
         headers: headers

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['knowledge_base_id']).to eq(knowledge_base.id)
    expect(EvoAiCoreService).to have_received(:update_agent)
  end

  it 'shows the current attachment' do
    AiAgentKnowledgeBase.create!(ai_agent_id: ai_agent_id, knowledge_base: knowledge_base, knowledge_tags: [])

    get "/api/v1/ai_agents/#{ai_agent_id}/knowledge_base", headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['knowledge_base_id']).to eq(knowledge_base.id)
  end

  it 'returns 404 when no knowledge base is attached' do
    get "/api/v1/ai_agents/#{ai_agent_id}/knowledge_base", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it 'detaches a knowledge base from an agent' do
    AiAgentKnowledgeBase.create!(ai_agent_id: ai_agent_id, knowledge_base: knowledge_base, knowledge_tags: [])

    delete "/api/v1/ai_agents/#{ai_agent_id}/knowledge_base", headers: headers

    expect(response).to have_http_status(:no_content)
    expect(AiAgentKnowledgeBase.find_by(ai_agent_id: ai_agent_id)).to be_nil
    expect(EvoAiCoreService).to have_received(:update_agent)
  end
end
