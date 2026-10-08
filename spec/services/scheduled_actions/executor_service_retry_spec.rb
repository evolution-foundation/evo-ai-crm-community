# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe ScheduledActions::ExecutorService do
  include ActiveJob::TestHelper

  let(:webhook_url) { 'https://hooks.example.com/scheduled' }
  let(:creator) { User.create!(email: "creator-#{SecureRandom.hex(4)}@example.com", name: 'Creator') }
  let(:contact) { Contact.create!(name: 'Jane Doe', email: "jane-#{SecureRandom.hex(4)}@example.com") }
  let(:recurrence_type) { nil }
  let!(:action) do
    ScheduledAction.create!(
      contact: contact,
      creator: creator,
      notifier: creator,
      action_type: 'execute_webhook',
      scheduled_for: 1.minute.from_now,
      recurrence_type: recurrence_type,
      payload: { 'webhook_url' => webhook_url, 'data' => { 'ok' => true } }
    )
  end

  before { travel 2.minutes }

  def run_due_actions
    ScheduledActionsProcessorJob.perform_now
    action.reload
  end

  def run_retry
    ScheduledActionsProcessorJob.perform_now(action.id)
    action.reload
  end

  def notification_types
    action.notifications.pluck(:notification_type)
  end

  context 'when the failure is transient' do
    before do
      stub_request(:post, webhook_url).to_return({ status: 500 }, { status: 200 })
    end

    it 'retries after the backoff and completes' do
      expect { run_due_actions }
        .to have_enqueued_job(ScheduledActionsProcessorJob).with(action.id).at(a_value_within(5.seconds).of(5.minutes.from_now))
      expect(action).to have_attributes(status: 'failed', retry_count: 1)

      run_retry

      expect(action).to have_attributes(status: 'completed', retry_count: 1, error_message: nil)
      expect(a_request(:post, webhook_url)).to have_been_made.twice
      expect(notification_types).to eq(['success'])
    end

    it 'does not run the retry when the action was cancelled while waiting' do
      run_due_actions
      action.mark_as_cancelled!

      run_retry

      expect(action.status).to eq('cancelled')
      expect(a_request(:post, webhook_url)).to have_been_made.once
    end
  end

  context 'when every attempt fails' do
    before { stub_request(:post, webhook_url).to_return(status: 500) }

    it 'ends failed with retry_count equal to max_retries and notifies the failure once' do
      run_due_actions
      expect { run_retry }.to have_enqueued_job(ScheduledActionsProcessorJob).with(action.id)
      expect { run_retry }.not_to have_enqueued_job(ScheduledActionsProcessorJob)
      run_retry

      expect(action).to have_attributes(status: 'failed', retry_count: action.max_retries)
      expect(action.error_message).to eq('Webhook failed with status 500')
      expect(a_request(:post, webhook_url)).to have_been_made.times(action.max_retries)
      expect(notification_types).to eq(['failure'])
      expect(action.notifications.first.message).to include('Webhook failed with status 500')
    end
  end

  context 'when the first attempt succeeds with a notifier set' do
    before { stub_request(:post, webhook_url).to_return(status: 200) }

    it 'completes once and notifies the success' do
      expect { run_due_actions }.not_to have_enqueued_job(ScheduledActionsProcessorJob)

      expect(action).to have_attributes(status: 'completed', retry_count: 0)
      expect(a_request(:post, webhook_url)).to have_been_made.once
      expect(notification_types).to eq(['success'])
    end
  end

  context 'when a step after completion raises' do
    let(:recurrence_type) { 'daily' }

    before do
      stub_request(:post, webhook_url).to_return(status: 200)
      # A daily action two days late books its next run in the past, which create! rejects.
      travel 2.days
    end

    it 'keeps the action completed and does not run it again' do
      expect { run_due_actions }.not_to have_enqueued_job(ScheduledActionsProcessorJob)

      expect(action).to have_attributes(status: 'completed', retry_count: 0)
      expect(a_request(:post, webhook_url)).to have_been_made.once
      expect(notification_types).to eq(['success'])
    end
  end
end
