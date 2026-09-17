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

    it 'compresses into a summary once compression_interval events have accumulated' do
      allow_any_instance_of(Memory::CompressionService).to receive(:call_llm).and_return('Rolled-up summary.')

      3.times do |i|
        post '/api/v1/internal/memory/event',
             params: { app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}", compression_interval: 3 }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)
      end

      summaries = MemorySummary.for(app_name: 'agent-1', user_id: 'user-1')
      expect(summaries.count).to eq(1)
      expect(summaries.first.content).to eq('Rolled-up summary.')
      expect(summaries.first.source_event_count).to eq(3)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(0)
    end

    it 'does not compress before compression_interval events have accumulated' do
      expect_any_instance_of(Memory::CompressionService).not_to receive(:call_llm)

      2.times do |i|
        post '/api/v1/internal/memory/event',
             params: { app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}", compression_interval: 3 }.to_json,
             headers: headers
      end

      expect(MemorySummary.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(0)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(2)
    end

    it 'returns 400 when app_name is missing' do
      post '/api/v1/internal/memory/event',
           params: { user_id: 'user-1', role: 'user', content: 'x' }.to_json,
           headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)['error']).to eq('app_name and user_id are required')
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

    it 'returns the newest matching memories first and does not let summaries starve events' do
      MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'topic summary one', source_event_count: 10, created_at: 4.hours.ago)
      MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'topic summary two', source_event_count: 10, created_at: 3.hours.ago)
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'topic event old', created_at: 2.hours.ago)
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'topic event new', created_at: 1.hour.ago)

      post '/api/v1/internal/memory/search',
           params: { app_name: 'agent-1', user_id: 'user-1', query: 'topic', max_results: 2 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      contents = JSON.parse(response.body)['memories'].map { |m| m['content'] }
      expect(contents).to eq(['topic event new', 'topic event old'])
    end

    it 'treats % in the query as a literal character rather than a wildcard' do
      MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'discount is 50% off', source_event_count: 10)
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'discount is fifty percent off')

      post '/api/v1/internal/memory/search',
           params: { app_name: 'agent-1', user_id: 'user-1', query: 'discount is 50% off', max_results: 5 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      contents = JSON.parse(response.body)['memories'].map { |m| m['content'] }
      expect(contents).to eq(['discount is 50% off'])
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

    # The real caller (HttpMemoryService.compress_memory) sends
    # `compression_interval`, not `interval`; without this example a regression
    # that drops the controller's compression_interval fallback would pass the
    # whole suite and silently break production.
    it 'honours compression_interval, the param name the processor actually sends' do
      10.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}") }
      allow_any_instance_of(Memory::CompressionService).to receive(:call_llm).and_return('Summary text.')

      post '/api/v1/internal/memory/compress',
           params: { app_name: 'agent-1', user_id: 'user-1', force: false, compression_interval: 10 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['success']).to eq(true)
      expect(body['summary_content']).to eq('Summary text.')
      expect(body['messages_compressed']).to eq(10)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(0)
    end

    it 'forces compression below the interval when force is true' do
      3.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}") }
      allow_any_instance_of(Memory::CompressionService).to receive(:call_llm).and_return('Forced summary.')

      post '/api/v1/internal/memory/compress',
           params: { app_name: 'agent-1', user_id: 'user-1', force: true, compression_interval: 10 }.to_json,
           headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['success']).to eq(true)
      expect(body['messages_compressed']).to eq(3)
      expect(MemorySummary.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(1)
    end

    it 'returns 502 with the error message when compression fails' do
      allow_any_instance_of(Memory::CompressionService).to receive(:compress!)
        .and_raise(Memory::CompressionService::Error, 'Compression LLM call returned 500: boom')

      post '/api/v1/internal/memory/compress',
           params: { app_name: 'agent-1', user_id: 'user-1', force: true, compression_interval: 10 }.to_json,
           headers: headers

      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)['error']).to eq('Compression LLM call returned 500: boom')
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

    it 'round-trips a dotted, email-shaped user_id without truncating it as a format extension' do
      post '/api/v1/internal/memory/event',
           params: { app_name: 'agent.one', user_id: 'user@example.com', role: 'user', content: 'x' }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)

      MemorySummary.create!(app_name: 'agent.one', user_id: 'user@example.com', content: 'y', source_event_count: 1)

      delete '/api/v1/internal/memory/agent.one/user@example.com', headers: headers

      expect(response).to have_http_status(:ok)
      expect(MemoryEvent.for(app_name: 'agent.one', user_id: 'user@example.com').count).to eq(0)
      expect(MemorySummary.for(app_name: 'agent.one', user_id: 'user@example.com').count).to eq(0)
    end
  end
end
