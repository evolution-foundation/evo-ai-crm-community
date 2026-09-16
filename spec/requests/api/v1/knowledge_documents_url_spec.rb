require 'rails_helper'
require 'webmock/rspec'

# Auth pattern copied from spec/requests/api/v1/agents_spec.rb (see Task 1.5's
# ledger ruling). Permission key reused from the ai_agents.* catalog resource.
RSpec.describe 'Api::V1::KnowledgeDocuments from_url', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:user) { User.create!(name: 'Knowledge URL Test User', email: "knowledge-url-#{SecureRandom.hex(4)}@example.com") }
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
    stub_request(:get, 'https://docs.example.com/guide').to_return(status: 200, body: '<html><body>Guide content</body></html>')
  end

  it 'creates a crawling document that crawls the URL asynchronously' do
    expect do
      post "/api/v1/knowledge_bases/#{knowledge_base.id}/documents/from_url",
           params: { url: 'https://docs.example.com/guide', include_subpages: false, max_pages: 1 }.to_json,
           headers: headers
    end.to have_enqueued_job(Knowledge::UrlIngestJob)

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['data']['status']).to eq('crawling')
  end
end
