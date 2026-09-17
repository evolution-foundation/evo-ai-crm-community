require 'rails_helper'

RSpec.describe 'Api::V1::Internal::Memory', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'Content-Type' => 'application/json', 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }
  after { ENV.delete('EVOAI_CRM_API_TOKEN') }

  describe 'POST /api/v1/internal/memory/event' do
    it 'stores an event and trims to max_messages' do
      3.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "old #{i}") }

      post '/api/v1/internal/memory/event',
           params: { app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'new message', max_messages: 2 }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').pluck(:content)).to eq(['old 2', 'new message'])
    end

    it 'rejects requests without a valid service token' do
      post '/api/v1/internal/memory/event',
           params: { app_name: 'a', user_id: 'u', role: 'user', content: 'x' }.to_json,
           headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/v1/internal/memory/search' do
    it 'returns matching summaries and events for a substring query' do
      MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'User prefers dark mode.', source_event_count: 10)
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'unrelated message')

      post '/api/v1/internal/memory/search',
           params: { app_name: 'agent-1', user_id: 'user-1', query: 'dark mode', max_results: 5 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['memories'].size).to eq(1)
      expect(body['memories'].first['content']).to eq('User prefers dark mode.')
    end
  end

  describe 'GET /api/v1/internal/memory/load' do
    it 'returns the latest summaries regardless of query' do
      older = MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'old summary', source_event_count: 10, created_at: 1.hour.ago)
      newer = MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'new summary', source_event_count: 10)

      get '/api/v1/internal/memory/load',
          params: { app_name: 'agent-1', user_id: 'user-1', max_results: 5 },
          headers: headers

      expect(response).to have_http_status(:ok)
      contents = JSON.parse(response.body)['memories'].map { |m| m['content'] }
      expect(contents).to eq([newer.content, older.content])
    end
  end

  describe 'POST /api/v1/internal/memory/compress' do
    it 'compresses accumulated events into a summary' do
      10.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}") }
      allow_any_instance_of(Memory::CompressionService).to receive(:call_llm).and_return('Summary text.')

      post '/api/v1/internal/memory/compress',
           params: { app_name: 'agent-1', user_id: 'user-1', force: false, interval: 10 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['success']).to eq(true)
      expect(body['summary_content']).to eq('Summary text.')
      expect(body['messages_compressed']).to eq(10)
    end

    it 'reports no compression when under the interval' do
      post '/api/v1/internal/memory/compress',
           params: { app_name: 'agent-1', user_id: 'user-1', force: false, interval: 10 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['success']).to eq(false)
      expect(body['messages_compressed']).to eq(0)
    end
  end

  describe 'DELETE /api/v1/internal/memory/:app_name/:user_id' do
    it 'clears all events and summaries for that pair' do
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'x')
      MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'y', source_event_count: 1)

      delete '/api/v1/internal/memory/agent-1/user-1', headers: headers

      expect(response).to have_http_status(:ok)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(0)
      expect(MemorySummary.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(0)
    end
  end
end
