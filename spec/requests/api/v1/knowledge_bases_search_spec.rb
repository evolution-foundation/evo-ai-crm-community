require 'rails_helper'
require 'webmock/rspec'

# Auth pattern copied from spec/requests/api/v1/agents_spec.rb (see Task 1.5's
# ledger ruling). Permission key reused from the ai_agents.* catalog resource.
RSpec.describe 'Api::V1::KnowledgeBases search', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:user) { User.create!(name: 'Knowledge Search Test User', email: "knowledge-search-#{SecureRandom.hex(4)}@example.com") }
  let(:knowledge_base) { create(:knowledge_base) }

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
          body: { success: true, data: { has_permission: %w[ai_agents.read ai_agents.create ai_agents.delete].include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
    document = create(:knowledge_document, knowledge_base: knowledge_base, status: 'active')
    create(:knowledge_entry, knowledge_document: document, content: 'resposta de teste', embedding: Array.new(1536, 0.1))
    allow_any_instance_of(Knowledge::EmbeddingService).to receive(:embed).and_return(Array.new(1536, 0.1))
  end

  it 'returns matching entries for the logged-in user' do
    post "/api/v1/knowledge_bases/#{knowledge_base.id}/search",
         params: { query: 'teste', max_results: 10 }.to_json,
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results'].first['content']).to eq('resposta de teste')
  end

  it 'returns an empty result set without calling the embedding service for a blank query' do
    expect_any_instance_of(Knowledge::EmbeddingService).not_to receive(:embed)

    post "/api/v1/knowledge_bases/#{knowledge_base.id}/search",
         params: { query: '', max_results: 10 }.to_json,
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results']).to eq([])
  end

  it 'clamps a negative max_results instead of erroring on LIMIT' do
    post "/api/v1/knowledge_bases/#{knowledge_base.id}/search",
         params: { query: 'teste', max_results: -5 }.to_json,
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results'].first['content']).to eq('resposta de teste')
  end

  it 'clamps a zero max_results up to at least 1' do
    post "/api/v1/knowledge_bases/#{knowledge_base.id}/search",
         params: { query: 'teste', max_results: 0 }.to_json,
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results'].size).to eq(1)
  end

  it 'returns a 502 when the embedding service fails' do
    allow_any_instance_of(Knowledge::EmbeddingService).to receive(:embed)
      .and_raise(Knowledge::EmbeddingService::Error, 'embedding provider unavailable')

    post "/api/v1/knowledge_bases/#{knowledge_base.id}/search",
         params: { query: 'teste', max_results: 10 }.to_json,
         headers: headers

    expect(response).to have_http_status(:bad_gateway)
    expect(JSON.parse(response.body)['error']).to eq('embedding provider unavailable')
  end
end
