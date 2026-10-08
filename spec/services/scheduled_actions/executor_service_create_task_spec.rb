# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledActions::ExecutorService, '#create_task' do
  let(:user) { User.create!(email: "sa-task-#{SecureRandom.hex(4)}@example.com", name: 'Scheduler') }
  let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Lead', position: 1) }
  let(:contact) { Contact.create!(name: 'Jane', email: "jane-#{SecureRandom.hex(4)}@example.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:payload) { { 'task_title' => 'Call back', 'task_description' => 'Ask about the proposal' } }
  let(:scheduled_action) do
    ScheduledAction.create!(
      contact: contact,
      action_type: 'create_task',
      scheduled_for: 1.minute.from_now,
      payload: payload,
      created_by: user.id
    )
  end

  def run_task_action
    described_class.new(scheduled_action).send(:execute_create_task)
  end

  def contact_card(pipeline_for_card = pipeline)
    stage_for_card = pipeline_for_card.pipeline_stages.first ||
                     PipelineStage.create!(pipeline: pipeline_for_card, name: 'Lead', position: 1)
    PipelineItem.create!(pipeline: pipeline_for_card, pipeline_stage: stage_for_card, contact: contact)
  end

  it 'creates the task on the contact card with the payload sent by the scheduling modal' do
    card = contact_card

    result = run_task_action

    expect(result[:success]).to be(true)
    task = card.tasks.sole
    expect(task.title).to eq('Call back')
    expect(task.description).to eq('Ask about the proposal')
    expect(task.created_by_id).to eq(user.id)
    expect(result[:data]).to include(task_id: task.id, pipeline_item_id: card.id)
  end

  it 'completes the action when run through execute' do
    contact_card
    scheduled_action.update!(scheduled_for: 1.second.ago)

    expect(described_class.new(scheduled_action).execute).to be(true)
    expect(scheduled_action.reload.status).to eq('completed')
  end

  it 'accepts the title and description keys of the API payload' do
    card = contact_card
    payload.replace('title' => 'Api title', 'description' => 'Api description')

    run_task_action

    expect(card.tasks.sole).to have_attributes(title: 'Api title', description: 'Api description')
  end

  it 'finds the card of a conversation that belongs to the contact' do
    Pipelines::ConversationService.new(pipeline: pipeline, user: user).add_conversation(conversation, stage: stage)

    result = run_task_action

    expect(result[:success]).to be(true)
    expect(conversation.pipeline_items.first.tasks.count).to eq(1)
  end

  it 'prefers the card of the action conversation over a more recent contact card' do
    Pipelines::ConversationService.new(pipeline: pipeline, user: user).add_conversation(conversation, stage: stage)
    conversation_card = conversation.pipeline_items.first
    conversation_card.update_column(:updated_at, 1.day.ago)
    other = Pipeline.create!(name: 'Support', pipeline_type: 'sales', created_by: user)
    contact_card(other)
    scheduled_action.update!(conversation: conversation)

    run_task_action

    expect(conversation_card.tasks.count).to eq(1)
  end

  it 'uses the most recently updated card when the contact has several' do
    older = contact_card
    older.update_column(:updated_at, 2.days.ago)
    newer = contact_card(Pipeline.create!(name: 'Support', pipeline_type: 'sales', created_by: user))

    run_task_action

    expect(newer.tasks.count).to eq(1)
    expect(older.tasks.count).to eq(0)
  end

  it 'skips cards of archived pipelines and closed cards' do
    contact_card.update!(completed_at: Time.current)
    archived = Pipeline.create!(name: 'Old', pipeline_type: 'sales', created_by: user)
    contact_card(archived)
    archived.update!(is_active: false)

    result = run_task_action

    expect(result).to eq(success: false, error: 'Contact has no open pipeline item to attach the task to')
    expect(PipelineTask.count).to eq(0)
  end

  it 'skips a private pipeline the action creator cannot open' do
    owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner')
    contact_card(Pipeline.create!(name: 'Private', pipeline_type: 'sales', created_by: owner))

    expect(run_task_action).to eq(success: false, error: 'Contact has no open pipeline item to attach the task to')
    expect(PipelineTask.count).to eq(0)
  end

  it 'reaches any pipeline when the action came in with the service token' do
    owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner')
    card = contact_card(Pipeline.create!(name: 'Private', pipeline_type: 'sales', created_by: owner))
    service_user = User.create!(email: ScheduledAction::SERVICE_CREATOR_EMAIL, name: 'System')
    scheduled_action.update!(created_by: service_user.id)

    run_task_action

    expect(card.tasks.count).to eq(1)
  end

  it 'uses the card the action names over a more recent one' do
    named = contact_card
    named.update_column(:updated_at, 2.days.ago)
    contact_card(Pipeline.create!(name: 'Support', pipeline_type: 'sales', created_by: user))
    payload['pipeline_item_id'] = named.id

    run_task_action

    expect(named.tasks.count).to eq(1)
  end

  it 'fails instead of falling back when the named card is closed' do
    named = contact_card
    contact_card(Pipeline.create!(name: 'Support', pipeline_type: 'sales', created_by: user))
    named.update!(completed_at: Time.current)
    payload['pipeline_item_id'] = named.id

    expect(run_task_action).to eq(
      success: false, error: 'Pipeline item of the action is closed or not accessible to its creator'
    )
    expect(PipelineTask.count).to eq(0)
  end

  it 'fails without creating anything when the contact has no card' do
    result = run_task_action

    expect(result).to eq(success: false, error: 'Contact has no open pipeline item to attach the task to')
    expect(PipelineTask.count).to eq(0)
  end

  it 'fails when the title is missing' do
    contact_card
    payload.replace('task_description' => 'no title')

    expect(run_task_action).to eq(success: false, error: 'Task title not provided')
  end

  it 'keeps a known assignee and drops an unknown one' do
    card = contact_card
    assignee = User.create!(email: "assignee-#{SecureRandom.hex(4)}@example.com", name: 'Assignee')
    scheduled_action.update!(payload: payload.merge('assigned_to' => assignee.id))
    run_task_action

    scheduled_action.update!(payload: payload.merge('assigned_to' => SecureRandom.uuid))
    run_task_action

    expect(card.tasks.order(:created_at).pluck(:assigned_to_id)).to eq([assignee.id, nil])
  end
end
