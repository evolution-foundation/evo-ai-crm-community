require 'rails_helper'
require 'webmock/rspec'

# Auth pattern copied from spec/requests/api/v1/knowledge_bases_search_spec.rb
# (see Task 1.5's ledger ruling).
RSpec.describe 'Api::V1::KnowledgeBases', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:user) { User.create!(name: 'Knowledge Base Test User', email: "knowledge-base-#{SecureRandom.hex(4)}@example.com") }

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
  end

  describe 'POST /api/v1/knowledge_bases' do
    it 'ignores an embedding_model supplied by the caller, keeping the fixed default' do
      post '/api/v1/knowledge_bases',
           params: { knowledge_base: { name: 'Custom KB', embedding_model: 'text-embedding-3-large' } }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      created = KnowledgeBase.find(JSON.parse(response.body)['data']['id'])
      expect(created.embedding_model).to eq('text-embedding-3-small')
    end
  end
end
