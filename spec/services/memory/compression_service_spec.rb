require 'rails_helper'

RSpec.describe Memory::CompressionService do
  subject(:service) { described_class.new }

  describe '#compress!' do
    it 'returns nil when there are no events to compress' do
      expect(service.compress!(app_name: 'agent-1', user_id: 'user-1', force: false, interval: 10)).to be_nil
    end

    it 'returns nil when under the interval and not forced' do
      5.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}") }

      expect(service.compress!(app_name: 'agent-1', user_id: 'user-1', force: false, interval: 10)).to be_nil
    end

    it 'compresses events into a summary and clears the compressed events when the interval is reached' do
      10.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: i.even? ? 'user' : 'agent', content: "msg #{i}") }
      allow_any_instance_of(described_class).to receive(:call_llm).and_return('Concise summary of the conversation.')

      summary = service.compress!(app_name: 'agent-1', user_id: 'user-1', force: false, interval: 10)

      expect(summary).to be_a(MemorySummary)
      expect(summary.content).to eq('Concise summary of the conversation.')
      expect(summary.source_event_count).to eq(10)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(0)
    end

    it 'forces compression below the interval when force is true' do
      3.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}") }
      allow_any_instance_of(described_class).to receive(:call_llm).and_return('Short summary.')

      summary = service.compress!(app_name: 'agent-1', user_id: 'user-1', force: true, interval: 10)

      expect(summary.source_event_count).to eq(3)
    end
  end
end
