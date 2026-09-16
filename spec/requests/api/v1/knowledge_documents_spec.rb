require 'rails_helper'
require 'webmock/rspec'

# Auth pattern copied from spec/requests/api/v1/agents_spec.rb — this codebase
# authenticates request specs via a stubbed external evo-auth-service, not
# Devise sign_in. See ledger ruling for Task 1.5.
RSpec.describe 'Api::V1::KnowledgeDocuments', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:user) { User.create!(name: 'Knowledge Test User', email: "knowledge-#{SecureRandom.hex(4)}@example.com") }
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

  def stub_auth(granted: %w[ai_agents.read ai_agents.create ai_agents.delete])
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
          body: { success: true, data: { has_permission: granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  before { stub_auth }

  it 'creates a manual knowledge document with tags' do
    post "/api/v1/knowledge_bases/#{knowledge_base.id}/documents",
         params: {
           knowledge_document: {
             title: 'Como configurar o sistema',
             description: 'Guia rápido',
             content: 'Conteúdo completo em markdown...',
             tags: ['vendas']
           }
         }.to_json,
         headers: headers

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['data']['title']).to eq('Como configurar o sistema')
    expect(body['data']['status']).to eq('processing')
  end

  it 'lists documents for a knowledge base' do
    create(:knowledge_document, knowledge_base: knowledge_base)

    get "/api/v1/knowledge_bases/#{knowledge_base.id}/documents", headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['data'].length).to eq(1)
  end
end
