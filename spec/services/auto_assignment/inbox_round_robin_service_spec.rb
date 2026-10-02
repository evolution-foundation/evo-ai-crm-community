# frozen_string_literal: true

require 'rails_helper'

# Member ids are UUID strings, and so is the queue read back from Redis. Casting
# the queue to integers never matches them, so the queue reset on every call and
# the same agent got every conversation.
RSpec.describe AutoAssignment::InboxRoundRobinService do
  let(:inbox) { Inbox.create!(name: 'Round Robin Inbox', channel: Channel::Api.create!) }
  let(:agents) do
    Array.new(3) { |i| User.create!(name: "Agent #{i}", email: "rr-#{i}-#{SecureRandom.hex(4)}@example.com") }
  end
  let(:agent_ids) { agents.map(&:id) }
  let(:round_robin_key) { format(Redis::Alfred::ROUND_ROBIN_AGENTS, inbox_id: inbox.id) }

  def service
    described_class.new(inbox: inbox)
  end

  def queue
    Redis::Alfred.lrange(round_robin_key)
  end

  before { agents.each { |agent| InboxMember.create!(inbox: inbox, user: agent) } }

  after { Redis::Alfred.delete(round_robin_key) }

  describe '#available_agent' do
    context 'when the queue matches the inbox members' do
      it 'validates the queue without resetting it' do
        instance = service
        expect(instance.send(:validate_queue?)).to be(true)

        expect(instance).not_to receive(:reset_queue)
        instance.available_agent(allowed_agent_ids: agent_ids)
      end

      it 'rotates through every agent before repeating one' do
        picks = Array.new(4) { service.available_agent(allowed_agent_ids: agent_ids) }

        expect(picks.first(3).map(&:id)).to match_array(agent_ids)
        expect(picks.last).to eq(picks.first)
      end

      it 'only picks among the allowed agents' do
        allowed = agent_ids.first(2)
        picks = Array.new(4) { service.available_agent(allowed_agent_ids: allowed) }

        expect(picks.map(&:id).uniq).to match_array(allowed)
      end
    end

    context 'when the queue diverges from the inbox members' do
      it 'resets the queue when a member is missing from it' do
        Redis::Alfred.lrem(round_robin_key, agent_ids.first)
        instance = service

        expect(instance).to receive(:reset_queue).and_call_original
        instance.available_agent(allowed_agent_ids: agent_ids)

        expect(queue).to match_array(agent_ids)
      end

      it 'resets the queue when it holds someone who is not a member' do
        Redis::Alfred.lpush(round_robin_key, SecureRandom.uuid)
        instance = service

        expect(instance).to receive(:reset_queue).and_call_original
        instance.available_agent(allowed_agent_ids: agent_ids)

        expect(queue).to match_array(agent_ids)
      end
    end
  end
end
