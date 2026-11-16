# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe PipelineTaskListener do
  include ActiveJob::TestHelper

  let(:listener) { described_class.instance }
  let(:user) { User.create!(name: 'Criador', email: %w[criador-tarefa example.com].join('@')) }
  let(:pipeline) { Pipeline.create!(name: 'Webhook Pipeline', pipeline_type: Pipeline::VALID_TYPES.first, created_by: user) }
  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
  let(:contact) { Contact.create!(name: 'Contato Tarefa') }
  let(:item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact) }
  let(:task) { PipelineTask.create!(pipeline_item: item, created_by: user, title: 'Ligar para o cliente') }

  before do
    Webhook.create!(url: 'https://hooks.example.com/tasks', webhook_type: :account_type,
                    subscriptions: %w[pipeline_task.completed pipeline_task.updated])
    Webhook.create!(url: 'https://hooks.example.com/messages', webhook_type: :account_type,
                    subscriptions: %w[message_created])
    clear_enqueued_jobs
  end

  def event_for(task)
    Events::Base.new('pipeline_task.completed', Time.zone.now, task: task)
  end

  it 'enqueues the webhook for each account webhook subscribed to the event' do
    listener.pipeline_task_completed(event_for(task))

    expect(WebhookJob).to have_been_enqueued.with(
      'https://hooks.example.com/tasks',
      hash_including(event: 'pipeline_task.completed', task_id: task.id, title: 'Ligar para o cliente')
    )
    expect(WebhookJob).not_to have_been_enqueued.with('https://hooks.example.com/messages', anything)
  end

  it 'skips an account webhook scoped to another inbox than the task conversation' do
    channel = Channel::Api.create!
    task_inbox = Inbox.create!(name: 'Task inbox', channel: channel)
    other_inbox = Inbox.create!(name: 'Other inbox', channel: Channel::Api.create!)
    customer = Contact.create!(name: 'Cliente da conversa')
    contact_inbox = ContactInbox.create!(inbox: task_inbox, contact: customer, source_id: SecureRandom.hex(4))
    conversation = Conversation.create!(inbox: task_inbox, contact: customer, contact_inbox: contact_inbox)
    conversation_item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    conversation_task = PipelineTask.create!(pipeline_item: conversation_item, created_by: user, title: 'Retornar')
    Webhook.create!(url: 'https://hooks.example.com/same-inbox', webhook_type: :account_type, inbox: task_inbox,
                    subscriptions: %w[pipeline_task.completed])
    Webhook.create!(url: 'https://hooks.example.com/other-inbox', webhook_type: :account_type, inbox: other_inbox,
                    subscriptions: %w[pipeline_task.completed])
    clear_enqueued_jobs

    listener.pipeline_task_completed(event_for(conversation_task))

    expect(WebhookJob).to have_been_enqueued.with('https://hooks.example.com/same-inbox', anything)
    expect(WebhookJob).not_to have_been_enqueued.with('https://hooks.example.com/other-inbox', anything)
  end

  it 'enqueues the created webhook even when the assignment notification raises' do
    Webhook.create!(url: 'https://hooks.example.com/created', webhook_type: :account_type,
                    subscriptions: %w[pipeline_task.created])
    assigned = PipelineTask.create!(pipeline_item: item, created_by: user, assigned_to: user, title: 'Com responsável')
    clear_enqueued_jobs
    allow(PipelineTasks::NotificationService).to receive(:new).and_raise(StandardError, 'notification down')

    expect { listener.pipeline_task_created(Events::Base.new('pipeline_task.created', Time.zone.now, task: assigned)) }
      .to raise_error(StandardError, 'notification down')
    expect(WebhookJob).to have_been_enqueued.with('https://hooks.example.com/created', anything)
  end

  it 'delivers without raising' do
    stub = stub_request(:post, 'https://hooks.example.com/tasks')
    perform_enqueued_jobs(only: WebhookJob) { listener.pipeline_task_updated(event_for(task)) }

    expect(stub).to have_been_requested.once
  end
end
