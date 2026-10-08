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
end
