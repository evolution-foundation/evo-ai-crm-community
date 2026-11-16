# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineTasks::NotificationService do
  include ActiveJob::TestHelper

  let(:assignee) { User.create!(name: 'Responsável', email: %w[responsavel-tarefa example.com].join('@')) }
  let(:creator) { User.create!(name: 'Criador', email: %w[criador-notif example.com].join('@')) }
  let(:pipeline) { Pipeline.create!(name: 'Notif Pipeline', pipeline_type: Pipeline::VALID_TYPES.first, created_by: creator) }
  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
  let(:item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: Contact.create!(name: 'Contato Notif')) }

  def task_due(due_date)
    PipelineTask.create!(pipeline_item: item, created_by: creator, assigned_to: assignee, title: 'Retornar ligação', due_date: due_date)
  end

  def notifications(type, task)
    Notification.where(user: assignee, notification_type: type, primary_actor: task)
  end

  it 'serializes a task as the notification primary actor' do
    task = task_due(2.days.from_now)
    notification = Notification.create!(user: assignee, notification_type: :pipeline_task_assigned, primary_actor: task, secondary_actor: item)

    expect(notification.push_event_data[:primary_actor]).to include(id: task.id, title: 'Retornar ligação', pipeline_item_id: item.id)
  end

  it 'notifies a task due soon once, however many times the reminder runs' do
    task = task_due(30.minutes.from_now)

    2.times { Pipelines::TaskDueSoonReminderJob.perform_now }

    expect(notifications(:pipeline_task_due_soon, task).count).to eq(1)
    expect(task.reload.metadata['due_soon_notification_sent_at']).to be_present
  end

  it 'marks an overdue task and records the notification' do
    task = task_due(10.minutes.ago)

    Pipelines::CheckOverdueTasksJob.perform_now

    expect(task.reload).to be_status_overdue
    expect(notifications(:pipeline_task_overdue, task).count).to eq(1)
    expect(task.metadata['last_overdue_notification_at']).to be_present
  end

  it 'sends the task email after creating the notification' do
    task = task_due(30.minutes.from_now)

    expect { Pipelines::TaskDueSoonReminderJob.perform_now }
      .to have_enqueued_mail(PipelineTaskMailer, :task_due_soon).with(task)
  end
end
