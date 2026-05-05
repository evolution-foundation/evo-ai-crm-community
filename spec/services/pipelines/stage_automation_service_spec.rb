# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageAutomationService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'custom', created_by: user) }
  let(:stage_a) { PipelineStage.create!(pipeline: pipeline, name: 'Stage A', position: 1) }
  let(:stage_b) { PipelineStage.create!(pipeline: pipeline, name: 'Stage B', position: 2) }
  let!(:pipeline_item) do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage_a, conversation: conversation)
  end

  subject(:service) { described_class.new(conversation, changed_attributes) }

  describe '#perform' do
    context 'with label_added trigger' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      context 'when trigger_value matches added label' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'move_to_stage', 'action_value' => stage_b.id }]
          })
        end

        it 'moves the conversation to the target stage' do
          expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
        end
      end

      context 'when trigger_value is blank (any label)' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => '',
                          'action' => 'move_to_stage', 'action_value' => stage_b.id }]
          })
        end

        it 'moves the conversation regardless of label name' do
          expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
        end
      end

      context 'when trigger_value does not match' do
        let(:changed_attributes) { { 'label_list' => [[], ['low-priority']] } }

        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'move_to_stage', 'action_value' => stage_b.id }]
          })
        end

        it 'does not move the conversation' do
          expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
        end
      end
    end

    context 'with conversation_status_changed trigger' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'move_to_stage', 'action_value' => stage_b.id }]
        })
      end

      it 'moves the conversation when status matches' do
        expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
      end

      context 'when status does not match' do
        let(:changed_attributes) { { 'status' => ['open', 'pending'] } }

        it 'does not move the conversation' do
          expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
        end
      end
    end

    context 'with custom_attribute_updated trigger' do
      let(:changed_attributes) { { 'custom_attributes' => [{}, { 'priority' => 'high' }] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'custom_attribute_updated', 'trigger_value' => '',
                        'action' => 'apply_label', 'action_value' => 'high-priority' }]
        })
      end

      it 'applies the label' do
        service.perform
        expect(conversation.reload.label_list).to include('high-priority')
      end
    end

    context 'with assign_agent action' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'assign_agent', 'action_value' => user.id }]
        })
      end

      it 'assigns the agent to the conversation' do
        service.perform
        expect(conversation.reload.assignee).to eq(user)
      end
    end

    context 'when stage has no automation rules' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      it 'does not raise an error' do
        expect { service.perform }.not_to raise_error
      end
    end

    context 'when conversation has no pipeline items' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before { pipeline_item.destroy! }

      it 'does nothing without error' do
        expect { service.perform }.not_to raise_error
      end
    end

    context 'when target_stage_id belongs to a different pipeline' do
      let(:other_pipeline) { Pipeline.create!(name: 'Other Pipeline', pipeline_type: 'custom', created_by: user) }
      let(:other_stage) { PipelineStage.create!(pipeline: other_pipeline, name: 'Other Stage', position: 1) }
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_stage', 'action_value' => other_stage.id }]
        })
      end

      it 'does not move to a stage from a different pipeline' do
        expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
      end
    end

    context 'loop prevention via Current.executed_by' do
      let(:changed_attributes) { { 'label_list' => [[], ['x']] } }

      it 'sets Current.executed_by to :stage_automation during execution' do
        stage_a.update!(automation_rules: { 'rules' => [] })
        executed_by_value = nil
        allow_any_instance_of(described_class).to receive(:evaluate_stage_rules) do
          executed_by_value = Current.executed_by
        end
        service.perform
        expect(executed_by_value).to eq(:stage_automation)
      end

      it 'resets Current after execution' do
        stage_a.update!(automation_rules: { 'rules' => [] })
        service.perform
        expect(Current.executed_by).to be_nil
      end
    end
  end
end
