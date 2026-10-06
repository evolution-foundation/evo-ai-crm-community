# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe EvoFlow::ScheduledActionEventsListener do
  let(:listener) { described_class.new }
  let(:contact_id) { '550e8400-e29b-41d4-a716-446655440001' }
  let(:scheduled_for) { Time.utc(2026, 10, 6, 14, 0, 0) }
  let(:attributes) do
    { id: 42, contact_id: contact_id, conversation_id: nil, conversation: nil, action_type: 'execute_webhook',
      scheduled_for: scheduled_for, status: 'completed', completed?: true, executed_at: scheduled_for + 5.seconds,
      error_message: nil, retry_count: 0, can_retry?: false, updated_at: scheduled_for + 5.seconds }
  end
  let(:action) { instance_double(ScheduledAction, **attributes) }

  before do
    Sidekiq::Testing.fake!
    EvoFlow::PublishEventWorker.clear
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return('test-key')
  end

  after { EvoFlow::PublishEventWorker.clear }

  def sent_payload
    EvoFlow::PublishEventWorker.jobs.last['args'][1]
  end

  def failed_action(**overrides)
    instance_double(
      ScheduledAction,
      **attributes, status: 'failed', completed?: false, executed_at: nil,
                    error_message: 'Webhook failed with status 500', retry_count: 1, can_retry?: true, **overrides
    )
  end

  it 'emits scheduled_action.executed with the action type and the due time' do
    listener.scheduled_action_outcome(data: { scheduled_action: action })

    expect(EvoFlow::PublishEventWorker.jobs.last['args'][0]).to eq('/events/track')
    expect(sent_payload['event']).to eq('scheduled_action.executed')
    expect(sent_payload['contactId']).to eq(contact_id)
    expect(sent_payload['properties']).to eq(
      'scheduled_action_id' => 42, 'action_type' => 'execute_webhook', 'scheduled_for' => '2026-10-06T14:00:00Z',
      'source' => 'scheduled_action', 'executed_at' => '2026-10-06T14:00:05Z'
    )
  end

  it 'emits scheduled_action.failed with the reason and whether it will retry' do
    listener.scheduled_action_outcome(data: { scheduled_action: failed_action })

    expect(sent_payload['event']).to eq('scheduled_action.failed')
    expect(sent_payload['properties']).to include(
      'error_message' => 'Webhook failed with status 500', 'retry_count' => 1, 'will_retry' => true
    )
    expect(sent_payload['properties']).not_to have_key('executed_at')
  end

  it 'truncates a long failure reason' do
    listener.scheduled_action_outcome(data: { scheduled_action: failed_action(error_message: 'x' * 2000) })

    expect(sent_payload['properties']['error_message'].length).to eq(500)
  end

  it 'gives each failed attempt its own message_id, stable across listener retries' do
    listener.scheduled_action_outcome(data: { scheduled_action: failed_action })
    first = sent_payload['messageId']
    listener.scheduled_action_outcome(data: { scheduled_action: failed_action })
    expect(sent_payload['messageId']).to eq(first)

    listener.scheduled_action_outcome(data: { scheduled_action: failed_action(retry_count: 2) })
    expect(sent_payload['messageId']).not_to eq(first)
  end

  it 'falls back to the conversation contact when the action has no contact' do
    conversation = instance_double(Conversation, contact_id: contact_id)
    conversation_id = '550e8400-e29b-41d4-a716-446655440002'
    action = instance_double(
      ScheduledAction, **attributes, contact_id: nil, conversation: conversation, conversation_id: conversation_id
    )

    listener.scheduled_action_outcome(data: { scheduled_action: action })

    expect(sent_payload['contactId']).to eq(contact_id)
    expect(sent_payload['properties']['conversation_id']).to eq(conversation_id)
  end

  it 'warns and does not enqueue when no contact resolves' do
    expect(Rails.logger).to receive(:warn).with(/no resolvable contact_id for scheduled_action 42/)

    listener.scheduled_action_outcome(data: { scheduled_action: instance_double(ScheduledAction, **attributes, contact_id: nil) })
    expect(EvoFlow::PublishEventWorker.jobs).to be_empty
  end

  it 'does not enqueue when EvoFlow is disabled' do
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil)
    allow(ENV).to receive(:[]).with('EVO_FLOW_ENABLED').and_return(nil)

    listener.scheduled_action_outcome(data: { scheduled_action: action })
    expect(EvoFlow::PublishEventWorker.jobs).to be_empty
  end

  it 'never raises: a builder failure is logged, not propagated to the executor' do
    allow(EvoFlow::PayloadBuilder).to receive(:build_track).and_raise(EvoFlow::InvalidEventPayload, 'boom')
    expect(Rails.logger).to receive(:error).with(/ScheduledActionEventsListener#scheduled_action_outcome failed/)

    expect { listener.scheduled_action_outcome(data: { scheduled_action: action }) }.not_to raise_error
  end
end
