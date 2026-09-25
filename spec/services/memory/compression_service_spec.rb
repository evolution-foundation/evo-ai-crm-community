require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Memory::CompressionService do
  subject(:service) { described_class.new }

  let(:app_name) { 'agent-1' }
  let(:user_id) { 'user-1' }

  def create_events(count, role: 'user', prefix: 'msg')
    count.times { |i| MemoryEvent.create!(app_name: app_name, user_id: user_id, role: role, content: "#{prefix} #{i}") }
  end

  def compress!(**overrides)
    service.compress!(app_name: app_name, user_id: user_id, force: false, interval: 10, **overrides)
  end

  describe '#compress!' do
    it 'returns nil when there are no events to compress' do
      expect(compress!).to be_nil
    end

    it 'returns nil when under the interval and not forced' do
      create_events(5)

      expect(compress!).to be_nil
    end

    it 'compresses events into a summary and clears the compressed events when the interval is reached' do
      create_events(10)
      allow_any_instance_of(described_class).to receive(:call_llm).and_return('Concise summary of the conversation.')

      summary = compress!

      expect(summary).to be_a(MemorySummary)
      expect(summary.content).to eq('Concise summary of the conversation.')
      expect(summary.source_event_count).to eq(10)
      expect(MemoryEvent.for(app_name: app_name, user_id: user_id).count).to eq(0)
    end

    it 'forces compression below the interval when force is true' do
      create_events(3)
      allow_any_instance_of(described_class).to receive(:call_llm).and_return('Short summary.')

      summary = compress!(force: true)

      expect(summary.source_event_count).to eq(3)
    end

    it 'holds a postgres advisory lock for the (app_name, user_id) pair while compressing' do
      create_events(10)

      held_advisory_locks = nil
      allow_any_instance_of(described_class).to receive(:call_llm) do
        held_advisory_locks = ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
        ).to_i
        'Concise summary of the conversation.'
      end

      compress!

      expect(held_advisory_locks).to eq(1)
    end

    it 'returns nil without calling the LLM when the advisory lock cannot be acquired' do
      create_events(10)

      connection = ActiveRecord::Base.connection
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(connection).to receive(:select_value).and_wrap_original do |original, sql, *args|
        sql.to_s.include?('pg_try_advisory_xact_lock') ? false : original.call(sql, *args)
      end

      expect_any_instance_of(described_class).not_to receive(:call_llm)

      expect(compress!).to be_nil
      expect(MemorySummary.where(app_name: app_name, user_id: user_id).count).to eq(0)
      expect(MemoryEvent.for(app_name: app_name, user_id: user_id).count).to eq(10)
    end

    it 'does not produce duplicate summaries when compress! is invoked again immediately after' do
      create_events(10)
      allow_any_instance_of(described_class).to receive(:call_llm).and_return('Concise summary of the conversation.')

      first = compress!
      second = compress!

      expect(first).to be_a(MemorySummary)
      expect(second).to be_nil
      expect(MemorySummary.where(app_name: app_name, user_id: user_id).count).to eq(1)
    end

    it 'raises a Memory::CompressionService::Error when the LLM response body is not valid JSON' do
      create_events(10)

      response = instance_double(Net::HTTPOK, code: '200', body: 'not json')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(response)
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint).with(for_consumer: :memory_compression)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'test-key', base_url: nil))

      expect { compress! }.to raise_error(Memory::CompressionService::Error, /unparseable JSON/)
    end

    it 'excludes events older than min_timestamp from the source transcript and leaves them uncompressed (EVO-2241 regression)' do
      create_events(5, role: 'agent', prefix: 'stale')
      travel_to(1.hour.from_now) { create_events(5, prefix: 'fresh') }

      captured_transcript = nil
      allow_any_instance_of(described_class).to receive(:call_llm) do |_, transcript|
        captured_transcript = transcript
        'Summary of only the fresh events.'
      end

      summary = compress!(min_timestamp: 30.minutes.from_now, force: true)

      expect(summary.source_event_count).to eq(5)
      expect(captured_transcript).not_to include('stale')
      expect(captured_transcript.scan(/fresh \d+/).size).to eq(5)
      # The pre-reset events are left alone - never summarized, never returned
      # (their created_at is permanently before any future min_timestamp).
      expect(MemoryEvent.for(app_name: app_name, user_id: user_id).count).to eq(5)
      expect(MemoryEvent.for(app_name: app_name, user_id: user_id).pluck(:content)).to all(start_with('stale'))
    end

    it 'uses the configured model override in the LLM request body' do
      allow(GlobalConfigService).to receive(:load).with('MEMORY_COMPRESSION_MODEL', 'gpt-4o-mini').and_return('gpt-4o')
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :memory_compression)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'sk-test-key', base_url: nil))
      create_events(10)

      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .with(body: hash_including(model: 'gpt-4o'))
        .to_return(status: 200, body: { choices: [{ message: { content: 'Summary.' } }] }.to_json)

      compress!

      expect(a_request(:post, 'https://api.openai.com/v1/chat/completions')
        .with(body: hash_including(model: 'gpt-4o'))).to have_been_made
    end
  end
end
