require 'rails_helper'

# RULING (see ledger): `ServiceToken` is NOT a database-backed model (there is
# no `service_tokens` table, no FactoryBot factory) — it's an ActiveModel
# wrapper that compares a header against ENV['EVOAI_CRM_API_TOKEN']. Auth
# pattern copied from the real example at
# spec/requests/api/v1/message_templates_service_token_spec.rb.
RSpec.describe 'Api::V1::Internal::Knowledge', type: :request do
  let(:knowledge_base) { create(:knowledge_base) }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'Content-Type' => 'application/json', 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  before do
    document = create(:knowledge_document, knowledge_base: knowledge_base, status: 'active')
    create(:knowledge_entry, knowledge_document: document, content: 'A resposta certa', embedding: Array.new(1536, 0.1))
    allow_any_instance_of(Knowledge::EmbeddingService).to receive(:embed).and_return(Array.new(1536, 0.1))
  end

  it 'returns matching entries for a valid service token' do
    post '/api/v1/internal/knowledge/search',
         params: { knowledge_base_id: knowledge_base.id, query: 'qual a resposta', max_results: 5 }.to_json,
         headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['results'].first['content']).to eq('A resposta certa')
  end

  it 'clamps a negative max_results instead of erroring on LIMIT' do
    post '/api/v1/internal/knowledge/search',
         params: { knowledge_base_id: knowledge_base.id, query: 'qual a resposta', max_results: -1 }.to_json,
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results'].first['content']).to eq('A resposta certa')
  end

  it 'rejects requests without a valid service token' do
    post '/api/v1/internal/knowledge/search',
         params: { knowledge_base_id: knowledge_base.id, query: 'qual a resposta' }.to_json,
         headers: { 'Content-Type' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end
end
