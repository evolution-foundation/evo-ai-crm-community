# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledAction, type: :model do
  let(:user) { User.create!(email: "sa-#{SecureRandom.hex(4)}@example.com", name: 'Scheduler') }
  let(:contact) { Contact.create!(name: 'Test Contact', email: "c-#{SecureRandom.hex(4)}@example.com") }
  let(:action) do
    described_class.create!(
      contact: contact, action_type: 'execute_webhook', scheduled_for: 1.hour.from_now,
      payload: { 'webhook_url' => 'https://example.com/hook' }, created_by: user.id
    )
  end

  # EvoFlow::ScheduledActionEventsListener consumes this broadcast to put the
  # outcome on the contact's events timeline.
  describe 'Wisper :scheduled_action_outcome broadcast' do
    let(:listener) do
      Class.new do
        attr_reader :events

        def initialize
          @events = []
        end

        def scheduled_action_outcome(data)
          @events << (data[:data] || data)
        end
      end.new
    end

    before { action.subscribe(listener) }

    it 'broadcasts when the action completes' do
      action.mark_as_executing!
      action.mark_as_completed!

      expect(listener.events.map { |e| e[:scheduled_action] }).to eq([action])
    end

    it 'broadcasts when the action fails' do
      action.mark_as_executing!
      action.mark_as_failed!('Webhook failed with status 500')

      expect(listener.events.size).to eq(1)
    end

    it 'broadcasts on a status change made outside the state machine methods' do
      action.update!(status: 'failed', error_message: 'Expired', retry_count: action.max_retries)

      expect(listener.events.size).to eq(1)
    end

    it 'does not broadcast again when an action that already failed is edited' do
      action.mark_as_executing!
      action.mark_as_failed!('Webhook failed with status 500')
      action.update!(max_retries: 5)

      expect(listener.events.size).to eq(1)
    end

    it 'stays quiet on changes that do not reach an outcome' do
      action.mark_as_executing!
      action.update!(payload: { 'webhook_url' => 'https://example.com/other' })
      action.mark_as_cancelled!

      expect(listener.events).to be_empty
    end
  end
end
