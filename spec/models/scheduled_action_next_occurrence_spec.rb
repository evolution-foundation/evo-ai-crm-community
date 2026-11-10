# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledAction, '#create_next_occurrence' do
  let(:user) { User.create!(email: "sa-next-#{SecureRandom.hex(4)}@example.com", name: 'Scheduler') }
  let(:contact) { Contact.create!(name: 'Jane', email: "jane-#{SecureRandom.hex(4)}@example.com") }
  let(:action) do
    described_class.create!(
      contact: contact,
      action_type: 'create_task',
      scheduled_for: 1.minute.from_now,
      payload: { 'task_title' => 'Call back' },
      created_by: user.id,
      notify_user_id: user.id,
      recurrence_type: 'daily'
    )
  end

  it 'books the next run of a completed recurring action' do
    action.mark_as_completed!

    next_action = action.create_next_occurrence

    expect(next_action).to have_attributes(
      contact_id: contact.id,
      action_type: 'create_task',
      payload: { 'task_title' => 'Call back' },
      recurrence_type: 'daily',
      notify_user_id: user.id,
      status: 'scheduled',
      scheduled_for: action.scheduled_for + 1.day
    )
  end

  it 'skips the runs missed by a late execution' do
    action.mark_as_completed!
    travel 2.days + 2.minutes

    expect(action.create_next_occurrence.scheduled_for).to eq(action.scheduled_for + 3.days)
  end

  context 'when the action was scheduled on a pipeline card' do
    let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
    let(:card) do
      PipelineItem.create!(pipeline: pipeline, pipeline_stage: pipeline.pipeline_stages.create!(name: 'New', position: 1),
                           contact: contact)
    end

    before { action.update!(pipeline_item_id: card.id, deal_id: 42) }

    it 'keeps the next run on the card and the legacy deal_id as it was' do
      action.mark_as_completed!

      expect(action.create_next_occurrence).to have_attributes(pipeline_item_id: card.id, deal_id: 42)
    end

    it 'still books the next run on the contact once the card is gone' do
      action.mark_as_completed!
      card.destroy!

      expect(action.reload.create_next_occurrence).to have_attributes(pipeline_item_id: nil, contact_id: contact.id)
    end
  end
end
