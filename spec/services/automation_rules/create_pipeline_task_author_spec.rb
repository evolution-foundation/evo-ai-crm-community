# frozen_string_literal: true

require 'rails_helper'

# Do not stub the SuperAdmin lookup here: it would hand the action a user no install of
# this product has, and the action's own rescue hides the difference.
RSpec.describe 'Automation rule create_pipeline_task author' do
  let(:owner) { User.create!(name: 'Funnel Owner', email: "owner-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:pipeline) { Pipeline.create!(name: "Board #{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: owner) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'S1', position: 1) }
  let!(:pipeline_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation) }

  let(:rule) do
    AutomationRule.create!(
      name: "Rule #{SecureRandom.hex(3)}",
      event_name: 'conversation_created',
      conditions: [],
      actions: [{ 'action_name' => 'create_pipeline_task',
                  'action_params' => [{ 'title' => 'Call the customer', 'task_type' => 'call',
                                        'priority' => 'medium' }] }],
      active: true
    )
  end

  after { Current.reset }

  def perform(recorder: nil)
    AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
  end

  describe 'an install with no SuperAdmin row (every install)' do
    it 'creates the task' do
      expect { perform }.to change { pipeline_item.reload.tasks.count }.from(0).to(1)
    end

    it 'records the funnel owner as the author' do
      perform

      expect(pipeline_item.reload.tasks.last.created_by_id).to eq(owner.id)
    end

    it 'keeps the run status clean, with no skip step' do
      recorder = AutomationRules::RunRecorder.new(rule: rule, event_name: 'conversation_created', payload: {})
      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!
      run = AutomationRuleRun.where(event_name: 'conversation_created').last

      expect(run.status).to eq('matched')
      expect(run.steps.map { |s| s['label'] }).not_to include(a_string_matching(/Skipped/))
    end
  end

  describe 'an install that still carries a SuperAdmin row' do
    before do
      legacy = User.create!(name: 'Legacy', email: "legacy-#{SecureRandom.hex(4)}@test.com")
      # update_all because assigning the type through the model needs the class to exist.
      User.where(id: legacy.id).update_all(type: 'SuperAdmin') # rubocop:disable Rails/SkipsModelValidations
    end

    it 'still creates the task, without touching the legacy row' do
      expect { perform }.to change { pipeline_item.reload.tasks.count }.from(0).to(1)
      expect(pipeline_item.reload.tasks.last.created_by_id).to eq(owner.id)
    end
  end

  describe 'when the board owner is gone' do
    let(:assignee) { User.create!(name: 'Assignee', email: "assignee-#{SecureRandom.hex(4)}@test.com") }

    before do
      conversation.update!(assignee: assignee)
      User.where(id: owner.id).delete_all
    end

    it 'records the conversation assignee as the author' do
      expect { perform }.to change { pipeline_item.reload.tasks.count }.from(0).to(1)
      expect(pipeline_item.reload.tasks.last.created_by_id).to eq(assignee.id)
    end
  end

  describe 'when the board owner and the assignee are both gone' do
    let(:assigner) { User.create!(name: 'Assigner', email: "assigner-#{SecureRandom.hex(4)}@test.com") }

    before do
      pipeline_item.update!(assigned_by: assigner)
      User.where(id: owner.id).delete_all
    end

    it "records the item's assigner as the author" do
      expect { perform }.to change { pipeline_item.reload.tasks.count }.from(0).to(1)
      expect(pipeline_item.reload.tasks.last.created_by_id).to eq(assigner.id)
    end
  end

  describe 'when no candidate author exists' do
    before { User.where(id: owner.id).delete_all }

    it 'creates no task' do
      expect { perform }.not_to change { pipeline_item.reload.tasks.count }.from(0)
    end

    it 'reports the refusal on the execution timeline and downgrades the run' do
      recorder = AutomationRules::RunRecorder.new(rule: rule, event_name: 'conversation_created', payload: {})
      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!
      run = AutomationRuleRun.where(event_name: 'conversation_created').last

      expect(run.status).to eq('skipped')
      expect(run.steps.map { |s| s['label'] }).to include('Skipped: create_pipeline_task')
      expect(run.steps.map { |s| s['data'] }).to include(hash_including('reason' => 'no_task_creator'))
    end

    it 'logs the refusal naming the action' do
      allow(Rails.logger).to receive(:warn)

      perform

      expect(Rails.logger).to have_received(:warn).with(/skipping create_pipeline_task/)
    end
  end

  describe 'flow-canvas surface' do
    let(:flow_service) { AutomationRules::FlowExecutionService.new(rule, nil, conversation) }
    let(:node) do
      { 'type' => 'create-pipeline-task-node', 'id' => 'n1',
        'data' => { 'title' => 'Follow up', 'task_type' => 'call', 'priority' => 'medium' } }
    end

    it 'creates the task with the funnel owner as author' do
      expect { flow_service.send(:execute_node_action, node) }
        .to change { pipeline_item.reload.tasks.count }.from(0).to(1)

      expect(pipeline_item.reload.tasks.last.created_by_id).to eq(owner.id)
    end
  end
end
