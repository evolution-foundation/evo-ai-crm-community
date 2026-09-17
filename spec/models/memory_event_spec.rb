require 'rails_helper'

RSpec.describe MemoryEvent, type: :model do
  describe '.for' do
    it 'returns events for the given app_name/user_id ordered oldest-first' do
      older = MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'first', created_at: 2.hours.ago)
      newer = MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'second', created_at: 1.hour.ago)
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'other-user', role: 'user', content: 'not this one')

      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').to_a).to eq([older, newer])
    end
  end

  describe '.trim_to!' do
    it 'deletes the oldest rows beyond max_messages and keeps the newest' do
      5.times { |i| MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: "msg #{i}", created_at: (10 - i).minutes.ago) }

      deleted = MemoryEvent.trim_to!(app_name: 'agent-1', user_id: 'user-1', max_messages: 3)

      expect(deleted).to eq(2)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').pluck(:content)).to eq(['msg 2', 'msg 3', 'msg 4'])
    end

    it 'does nothing when under the limit' do
      MemoryEvent.create!(app_name: 'agent-1', user_id: 'user-1', role: 'user', content: 'only one')

      deleted = MemoryEvent.trim_to!(app_name: 'agent-1', user_id: 'user-1', max_messages: 50)

      expect(deleted).to eq(0)
      expect(MemoryEvent.for(app_name: 'agent-1', user_id: 'user-1').count).to eq(1)
    end
  end
end
