# frozen_string_literal: true

require 'rails_helper'

# Validation coverage for AutomationRules::ActionService#update_pipeline_stage
# in the path where the conversation is not yet a member of the target pipeline.
#
# EVO-1080: confirm that the action lands the conversation on the requested
# stage of the target pipeline, not the first stage of that pipeline. The
# implementation in action_service.rb#auto_assign_and_move_to_stage attaches
# the conversation at the first stage via add_conversation and then calls
# move_to_target_stage_after_assignment to move it to the requested stage.
# This spec is a regression guard for that two-step sequence; removing the
# follow-up move would silently leave conversations on the wrong stage.

RSpec.describe AutomationRules::ActionService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:pipeline_a) { Pipeline.create!(name: 'Source pipeline', pipeline_type: 'custom', created_by: user) }
  let!(:stage_a1) { PipelineStage.create!(pipeline: pipeline_a, name: 'A1', position: 1) }

  let(:pipeline_b) { Pipeline.create!(name: 'Target pipeline', pipeline_type: 'custom', created_by: user) }
  let!(:stage_b1) { PipelineStage.create!(pipeline: pipeline_b, name: 'B1', position: 1) }
  let!(:stage_b2) { PipelineStage.create!(pipeline: pipeline_b, name: 'B2', position: 2) }
  let!(:stage_b3) { PipelineStage.create!(pipeline: pipeline_b, name: 'B3', position: 3) }

  def build_rule_with_stage_action(stage)
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: 'conversation_updated',
      active: true,
      mode: 'simple',
      conditions: [],
      actions: [{ 'action_name' => 'update_pipeline_stage', 'action_params' => [stage.id] }]
    )
    rule.save!(validate: false)
    rule
  end

  describe '#update_pipeline_stage (auto-assign-and-move path)' do
    context 'when the conversation belongs to a different pipeline and the target stage is NOT the first of the new pipeline' do
      before do
        PipelineItem.create!(pipeline: pipeline_a, pipeline_stage: stage_a1, conversation: conversation)
      end

      it 'attaches the conversation to the target pipeline on the requested stage (not the first)' do
        rule = build_rule_with_stage_action(stage_b3)
        described_class.new(rule, nil, conversation).perform

        conversation.reload
        items = conversation.pipeline_items
        expect(items.count).to eq(1)
        expect(items.first.pipeline).to eq(pipeline_b)
        expect(items.first.pipeline_stage).to eq(stage_b3)
      end

      it 'destroys the previous pipeline assignment (assign_to_pipeline-style behaviour)' do
        rule = build_rule_with_stage_action(stage_b2)
        described_class.new(rule, nil, conversation).perform

        conversation.reload
        expect(conversation.pipeline_items.where(pipeline: pipeline_a)).to be_empty
        expect(conversation.pipeline_items.where(pipeline: pipeline_b)).to exist
      end
    end

    context 'when the conversation is not in any pipeline yet' do
      it 'attaches the conversation to the target pipeline on the requested stage' do
        rule = build_rule_with_stage_action(stage_b2)
        described_class.new(rule, nil, conversation).perform

        conversation.reload
        items = conversation.pipeline_items
        expect(items.count).to eq(1)
        expect(items.first.pipeline_stage).to eq(stage_b2)
      end
    end

    context 'when the target stage is already the first stage of the target pipeline' do
      it 'still attaches the conversation to that stage' do
        rule = build_rule_with_stage_action(stage_b1)
        described_class.new(rule, nil, conversation).perform

        conversation.reload
        expect(conversation.pipeline_items.first.pipeline_stage).to eq(stage_b1)
      end
    end
  end

  describe '#update_pipeline_stage (move-existing path)' do
    before do
      PipelineItem.create!(pipeline: pipeline_b, pipeline_stage: stage_b1, conversation: conversation)
    end

    it 'moves an existing pipeline_item to the requested stage without recreating it' do
      original_item_id = conversation.pipeline_items.find_by(pipeline: pipeline_b).id
      rule = build_rule_with_stage_action(stage_b3)
      described_class.new(rule, nil, conversation).perform

      conversation.reload
      items = conversation.pipeline_items.where(pipeline: pipeline_b)
      expect(items.count).to eq(1)
      expect(items.first.pipeline_stage).to eq(stage_b3)
      expect(items.first.id).to eq(original_item_id)
    end
  end
end
