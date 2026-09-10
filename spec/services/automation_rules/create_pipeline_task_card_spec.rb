# frozen_string_literal: true

require 'rails_helper'

# The handlers are shared, so these examples drive both executor surfaces: the modal-style
# ActionService and the flow-canvas FlowExecutionService.
RSpec.describe 'Automation rule create_pipeline_task card selection' do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:funnel_a) { Pipeline.create!(name: 'Funnel A', pipeline_type: 'sales', created_by: user) }
  let!(:stage_a1) { PipelineStage.create!(pipeline: funnel_a, name: 'A1', position: 1) }

  let(:funnel_b) do
    Pipeline.create!(name: 'Funnel B', pipeline_type: 'sales', created_by: user)
            .tap { |funnel| PipelineStage.create!(pipeline: funnel, name: 'B1', position: 1) }
  end

  let(:task_params) { [{ 'title' => 'Call the customer', 'task_type' => 'call', 'priority' => 'medium' }] }

  def rule_with(actions)
    AutomationRule.create!(
      name: "Rule #{SecureRandom.hex(3)}",
      event_name: 'conversation_created',
      conditions: [],
      actions: actions,
      active: true
    )
  end

  def run(rule)
    AutomationRules::ActionService.new(rule, nil, conversation).perform
  end

  after { Current.reset }

  describe 'a conversation living in two funnels' do
    # Pinned to the lowest uuid: the old unordered `.first` resolved to `ORDER BY id`, so without
    # this the wrong card won only about half the runs.
    let!(:card_a) do
      PipelineItem.create!(id: '00000000-0000-4000-8000-000000000001',
                           pipeline: funnel_a, pipeline_stage: stage_a1,
                           conversation: conversation, created_at: 2.hours.ago)
    end

    let(:rule) do
      rule_with([{ 'action_name' => 'assign_to_pipeline', 'action_params' => [funnel_b.id] },
                 { 'action_name' => 'create_pipeline_task', 'action_params' => task_params }])
    end

    it 'writes the task on the card of the funnel the rule just acted on' do
      run(rule)

      card_b = conversation.pipeline_items.find_by(pipeline: funnel_b)
      expect(card_b.tasks.pluck(:title)).to eq(['Call the customer'])
    end

    it 'leaves the card of the other funnel without the task' do
      expect { run(rule) }.not_to change { card_a.reload.tasks.count }.from(0)
    end

    it 'creates exactly one task' do
      expect { run(rule) }.to change(PipelineTask, :count).by(1)
    end
  end

  describe 'a conversation already active in the funnel the rule names' do
    # No-op assignment: the card of the funnel the rule names is the older one.
    let!(:card_b) do
      PipelineItem.create!(pipeline: funnel_b, pipeline_stage: funnel_b.pipeline_stages.first,
                           conversation: conversation, created_at: 3.hours.ago)
    end
    let!(:card_a) do
      PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1,
                           conversation: conversation, created_at: 1.hour.ago)
    end

    it 'still writes the task on the card of the funnel the rule named' do
      run(rule_with([{ 'action_name' => 'assign_to_pipeline', 'action_params' => [funnel_b.id] },
                     { 'action_name' => 'create_pipeline_task', 'action_params' => task_params }]))

      expect(card_b.reload.tasks.count).to eq(1)
      expect(card_a.reload.tasks.count).to eq(0)
    end
  end

  describe 'a rule that moves the stage instead of assigning' do
    let!(:card_b) do
      PipelineItem.create!(pipeline: funnel_b, pipeline_stage: funnel_b.pipeline_stages.first,
                           conversation: conversation, created_at: 3.hours.ago)
    end
    let!(:card_a) do
      PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1,
                           conversation: conversation, created_at: 1.hour.ago)
    end

    it 'writes the task on the card of the funnel whose stage it moved' do
      stage_b2 = PipelineStage.create!(pipeline: funnel_b, name: 'B2', position: 2)

      run(rule_with([{ 'action_name' => 'update_pipeline_stage', 'action_params' => [stage_b2.id] },
                     { 'action_name' => 'create_pipeline_task', 'action_params' => task_params }]))

      expect(card_b.reload.tasks.count).to eq(1)
      expect(card_a.reload.tasks.count).to eq(0)
    end
  end

  describe 'a funnel that holds a completed card and an active one' do
    # Completed by update, not born completed: the uniqueness validation refuses a new completed row
    # while an active sibling exists. Newer than the active card, so only the filter keeps it out.
    let!(:completed_card) do
      item = PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1,
                                  conversation: conversation, created_at: 1.hour.ago)
      item.update!(completed_at: 30.minutes.ago)
      item
    end

    let!(:active_card) do
      PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1,
                           conversation: conversation, created_at: 2.hours.ago)
    end

    it 'writes the task on the active card' do
      run(rule_with([{ 'action_name' => 'create_pipeline_task', 'action_params' => task_params }]))

      expect(active_card.reload.tasks.count).to eq(1)
      expect(completed_card.reload.tasks.count).to eq(0)
    end
  end

  describe 'a funnel the rule named that refused the assignment' do
    let!(:card_a) do
      PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1,
                           conversation: conversation, created_at: 1.hour.ago)
    end
    let(:empty_funnel) { Pipeline.create!(name: 'No stages', pipeline_type: 'sales', created_by: user) }
    let(:rule) do
      rule_with([{ 'action_name' => 'assign_to_pipeline', 'action_params' => [empty_funnel.id] },
                 { 'action_name' => 'create_pipeline_task', 'action_params' => task_params }])
    end
    let(:recorder) do
      AutomationRules::RunRecorder.new(rule: rule, event_name: 'conversation_created', payload: {})
    end

    it 'creates no task instead of falling back to another funnel' do
      expect { run(rule) }.not_to change(PipelineTask, :count).from(0)

      expect(card_a.reload.tasks).to be_empty
    end

    it 'records the skip on the execution timeline' do
      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!

      run = AutomationRuleRun.where(automation_rule_id: rule.id).last
      skipped = run.steps.find { |s| s['label'] == 'Skipped: create_pipeline_task' }
      expect(skipped.dig('data', 'reason')).to eq('pipeline_target_missing')
      expect(skipped.dig('data', 'pipeline_id')).to eq(empty_funnel.id)
    end
  end

  describe 'a conversation whose only card is completed' do
    let!(:completed_card) do
      item = PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1, conversation: conversation)
      item.update!(completed_at: 30.minutes.ago)
      item
    end

    it 'creates no task' do
      expect { run(rule_with([{ 'action_name' => 'create_pipeline_task', 'action_params' => task_params }])) }
        .not_to change(PipelineTask, :count).from(0)

      expect(completed_card.reload.tasks).to be_empty
    end
  end

  describe 'flow-canvas surface' do
    let!(:card_a) do
      PipelineItem.create!(id: '00000000-0000-4000-8000-000000000001',
                           pipeline: funnel_a, pipeline_stage: stage_a1,
                           conversation: conversation, created_at: 2.hours.ago)
    end

    let(:rule) { rule_with([]) }
    let(:flow_service) { AutomationRules::FlowExecutionService.new(rule, nil, conversation) }

    it 'writes the task on the card of the funnel the flow just acted on' do
      flow_service.send(:execute_node_action,
                        { 'type' => 'assign-to-pipeline-node', 'id' => 'n1',
                          'data' => { 'pipeline_id' => funnel_b.id } })
      flow_service.send(:execute_node_action,
                        { 'type' => 'create-pipeline-task-node', 'id' => 'n2',
                          'data' => { 'title' => 'Follow up', 'task_type' => 'call', 'priority' => 'medium' } })

      card_b = conversation.pipeline_items.find_by(pipeline: funnel_b)
      expect(card_b.tasks.count).to eq(1)
      expect(card_a.reload.tasks.count).to eq(0)
    end
  end
end
