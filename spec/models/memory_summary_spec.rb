require 'rails_helper'

RSpec.describe MemorySummary, type: :model do
  describe '.for' do
    it 'returns summaries for the given app_name/user_id ordered newest-first' do
      older = MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'old summary', source_event_count: 5, created_at: 2.hours.ago)
      newer = MemorySummary.create!(app_name: 'agent-1', user_id: 'user-1', content: 'new summary', source_event_count: 5, created_at: 1.hour.ago)
      MemorySummary.create!(app_name: 'agent-1', user_id: 'other-user', content: 'not this one', source_event_count: 5)

      expect(MemorySummary.for(app_name: 'agent-1', user_id: 'user-1').to_a).to eq([newer, older])
    end
  end
end
