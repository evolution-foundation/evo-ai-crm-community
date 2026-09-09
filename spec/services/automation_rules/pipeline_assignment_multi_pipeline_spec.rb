# frozen_string_literal: true

require 'rails_helper'

# CRM-566 (SUPORTEEVO-23): `assign_to_pipeline` opened with
# `@conversation.pipeline_items.destroy_all`, and Pipelines::ConversationService#add_conversation
# destroyed every item in the OTHER pipelines right after. On an account with two funnels,
# sending a conversation to funnel B hard-deleted its card in funnel A — cascading into
# stage_movements, PipelineTasks and pipeline_item_products. Nothing recovers that from the app.
#
# The schema always said otherwise: idx_pipeline_items_active_conversation_per_pipeline is unique
# on (conversation_id, pipeline_id) WHERE completed_at IS NULL. Several funnels at once is the
# supported shape; twice in ONE funnel is what is forbidden, and the index already forbids it.
#
# The guard lives in the shared PipelineActionHandlers module, so it covers both executor
# surfaces (modal-style ActionService and flow-canvas FlowExecutionService).
RSpec.describe 'Automation rule pipeline assignment across several pipelines' do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  # Two commercial funnels on the same account, the shape the customer reported.
  let(:funnel_a) { Pipeline.create!(name: 'Funnel A', pipeline_type: 'sales', created_by: user) }
  let!(:stage_a1) { PipelineStage.create!(pipeline: funnel_a, name: 'A1', position: 1) }
  let!(:stage_a2) { PipelineStage.create!(pipeline: funnel_a, name: 'A2', position: 2) }

  let(:funnel_b) { Pipeline.create!(name: 'Funnel B', pipeline_type: 'sales', created_by: user) }
  let!(:stage_b1) { PipelineStage.create!(pipeline: funnel_b, name: 'B1', position: 1) }

  def rule_with(action_name, params)
    AutomationRule.create!(
      name: "Rule #{SecureRandom.hex(3)}",
      event_name: 'conversation_created',
      conditions: [],
      actions: [{ 'action_name' => action_name, 'action_params' => params }],
      active: true
    )
  end

  def run(rule)
    AutomationRules::ActionService.new(rule, nil, conversation).perform
  end

  after { Current.reset }

  describe 'assigning to a funnel the conversation is NOT in yet (AC1)' do
    # A card with real history behind it: it moved a stage (so stage_movements has more than the
    # entry row) and carries a task. Those are the associations `dependent: :destroy` took down.
    let!(:card_a) do
      item = PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1, conversation: conversation)
      item.move_to_stage(stage_a2)
      PipelineTask.create!(pipeline_item: item, created_by: user, title: 'Call the customer')
      item
    end

    it 'leaves the card in funnel A alive' do
      run(rule_with('assign_to_pipeline', [funnel_b.id]))

      expect(PipelineItem.find_by(id: card_a.id)).to be_present
    end

    it 'keeps the funnel A card in its own stage, not dragged to the new funnel' do
      run(rule_with('assign_to_pipeline', [funnel_b.id]))

      expect(card_a.reload.pipeline_id).to eq(funnel_a.id)
      expect(card_a.pipeline_stage_id).to eq(stage_a2.id)
    end

    it 'keeps the task on the funnel A card' do
      expect { run(rule_with('assign_to_pipeline', [funnel_b.id])) }
        .not_to change { PipelineTask.where(pipeline_item_id: card_a.id).count }.from(1)
    end

    it 'keeps the stage movement history of the funnel A card' do
      movements_before = card_a.stage_movements.count
      expect(movements_before).to be >= 2 # entry + the A1 -> A2 move

      expect { run(rule_with('assign_to_pipeline', [funnel_b.id])) }
        .not_to change { StageMovement.where(pipeline_item_id: card_a.id).count }.from(movements_before)
    end

    it 'creates the card in funnel B' do
      expect { run(rule_with('assign_to_pipeline', [funnel_b.id])) }
        .to change { conversation.reload.pipeline_items.active.where(pipeline: funnel_b).count }.from(0).to(1)
    end

    it 'ends with the conversation active in BOTH funnels' do
      run(rule_with('assign_to_pipeline', [funnel_b.id]))

      expect(conversation.reload.pipeline_items.active.map(&:pipeline_id))
        .to contain_exactly(funnel_a.id, funnel_b.id)
    end
  end

  describe 'assigning to a funnel the conversation is ALREADY in (AC2)' do
    let!(:card_b) do
      item = PipelineItem.create!(pipeline: funnel_b, pipeline_stage: stage_b1, conversation: conversation)
      PipelineTask.create!(pipeline_item: item, created_by: user, title: 'Send the proposal')
      item
    end

    it 'does not raise' do
      expect { run(rule_with('assign_to_pipeline', [funnel_b.id])) }.not_to raise_error
    end

    it 'creates no duplicate item' do
      expect { run(rule_with('assign_to_pipeline', [funnel_b.id])) }
        .not_to change { conversation.reload.pipeline_items.count }.from(1)
    end

    # The pre-fix code deleted and recreated the card, so the row was a different one and the
    # task went with it. A no-op has to be the SAME row.
    it 'keeps the very same card, with its task' do
      run(rule_with('assign_to_pipeline', [funnel_b.id]))

      expect(conversation.reload.pipeline_items.active.first.id).to eq(card_b.id)
      expect(card_b.reload.tasks.map(&:title)).to eq(['Send the proposal'])
    end

    it 'reports the no-op instead of a failure' do
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)

      run(rule_with('assign_to_pipeline', [funnel_b.id]))

      expect(Rails.logger).to have_received(:info).with(/already active in pipeline Funnel B.*no-op/)
      expect(Rails.logger).not_to have_received(:error).with(/Failed to assign/)
    end
  end

  # The unique index is partial on `completed_at IS NULL`, so a closed journey is history, not
  # an occupied slot: assigning again opens a NEW active card next to it.
  describe 'assigning to a funnel where an earlier journey was completed' do
    let!(:closed_card_b) do
      PipelineItem.create!(
        pipeline: funnel_b, pipeline_stage: stage_b1, conversation: conversation, completed_at: 1.day.ago
      )
    end

    it 'opens a new active card without touching the completed one' do
      expect { run(rule_with('assign_to_pipeline', [funnel_b.id])) }
        .to change { conversation.reload.pipeline_items.active.where(pipeline: funnel_b).count }.from(0).to(1)

      expect(PipelineItem.find_by(id: closed_card_b.id)).to be_present
      expect(closed_card_b.reload.completed_at).to be_present
    end
  end

  # update_pipeline_stage auto-assigns through the same Pipelines::ConversationService, so the
  # other half of the fix (prepare_conversation_for_pipeline) needs its own proof.
  describe 'update_pipeline_stage auto-assigning into a second funnel' do
    let!(:card_a) do
      PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1, conversation: conversation)
    end

    it 'does not destroy the card the conversation has in the other funnel' do
      run(rule_with('update_pipeline_stage', [stage_b1.id]))

      expect(PipelineItem.find_by(id: card_a.id)).to be_present
      expect(conversation.reload.pipeline_items.active.map(&:pipeline_id))
        .to contain_exactly(funnel_a.id, funnel_b.id)
    end
  end

  # Same handler module, second executor surface — the canvas node must not wipe funnels either.
  describe 'flow-canvas surface' do
    let(:flow_rule) { rule_with('assign_to_pipeline', [funnel_b.id]) }
    let(:flow_service) { AutomationRules::FlowExecutionService.new(flow_rule, nil, conversation) }
    let!(:card_a) do
      PipelineItem.create!(pipeline: funnel_a, pipeline_stage: stage_a1, conversation: conversation)
    end

    it 'adds the funnel B card and keeps the funnel A card' do
      node = { 'type' => 'assign-to-pipeline-node', 'id' => 'n1', 'data' => { 'pipeline_id' => funnel_b.id } }

      expect { flow_service.send(:execute_node_action, node) }
        .to change { conversation.reload.pipeline_items.active.count }.from(1).to(2)

      expect(PipelineItem.find_by(id: card_a.id)).to be_present
    end
  end
end
