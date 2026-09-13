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

    context 'with remove_label action' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        conversation.update!(label_list: ['lead', 'contacted'])
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'remove_label', 'action_value' => 'lead' }]
        })
      end

      it 'removes the label from the conversation' do
        service.perform
        expect(conversation.reload.label_list).not_to include('lead')
        expect(conversation.reload.label_list).to include('contacted')
      end
    end

    context 'with assign_team action' do
      let(:team) { Team.create!(name: 'Sales Team') }
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'assign_team', 'action_value' => team.id }]
        })
      end

      it 'assigns the team to the conversation' do
        service.perform
        expect(conversation.reload.team).to eq(team)
      end
    end

    context 'with change_priority action' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'change_priority', 'action_value' => 'urgent' }]
        })
      end

      it 'changes conversation priority' do
        service.perform
        expect(conversation.reload.priority).to eq('urgent')
      end
    end

    context 'with create_pipeline_task action' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'create_pipeline_task', 'action_value' => 'Follow up on proposal' }]
        })
      end

      it 'creates a task on the pipeline item' do
        expect { service.perform }.to change { pipeline_item.tasks.count }.by(1)
        expect(pipeline_item.tasks.last.title).to eq('Follow up on proposal')
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

    # EVO-2201: an archived pipeline must stop acting on its own — its rules can message
    # the customer from a board the operator turned off and can no longer see.
    context 'when the pipeline is archived' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_stage', 'action_value' => stage_b.id }]
        })
      end

      it 'does not execute the rule' do
        pipeline.update!(is_active: false)

        expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
      end

      it 'logs the skip with the pipeline id and the reason' do
        pipeline.update!(is_active: false)
        allow(Rails.logger).to receive(:warn)

        service.perform

        expect(Rails.logger).to have_received(:warn).with(/#{pipeline.id} is archived/)
      end

      it 'still executes the rule while the pipeline is active' do
        expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
      end

      # A conversation may sit in several pipelines: one archived must not silence the rest.
      it 'evaluates the active pipeline of a conversation that also sits in an archived one' do
        pipeline.update!(is_active: false)

        live = Pipeline.create!(name: 'Live', pipeline_type: 'custom', created_by: user)
        live_a = PipelineStage.create!(pipeline: live, name: 'A', position: 1)
        live_b = PipelineStage.create!(pipeline: live, name: 'B', position: 2)
        live_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_stage', 'action_value' => live_b.id }]
        })
        live_item = PipelineItem.create!(pipeline: live, pipeline_stage: live_a, conversation: conversation)

        service.perform

        expect(live_item.reload.pipeline_stage_id).to eq(live_b.id)
        expect(pipeline_item.reload.pipeline_stage_id).to eq(stage_a.id)
      end
    end

    # Refusing the move keeps the conversation visible where it is, instead of pushing it
    # into a board nobody can see.
    context 'when move_to_pipeline targets an archived pipeline' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }
      let(:target) do
        t = Pipeline.create!(name: 'Target', pipeline_type: 'custom', created_by: user)
        PipelineStage.create!(pipeline: t, name: 'Inbox', position: 1)
        t
      end

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_pipeline', 'action_value' => target.id }]
        })
      end

      # move_to_pipeline relocates the existing item rather than creating a second one.
      it 'refuses the move and says why' do
        target.update!(is_active: false)
        allow(Rails.logger).to receive(:warn)

        expect { service.perform }.not_to change { pipeline_item.reload.pipeline_id }
        expect(Rails.logger).to have_received(:warn).with(/#{target.id} is archived/)
      end

      it 'performs the move while the target is active' do
        expect { service.perform }.to change { pipeline_item.reload.pipeline_id }.to(target.id)
      end
    end

    # EVO: send_template rules may carry action_variables/action_variable_fallbacks so a
    # WhatsApp template's {{1}}-style placeholders get filled instead of sent literally.
    context 'with send_template action carrying action_variables' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }
      let(:template) do
        MessageTemplate.create!(name: "hello-#{SecureRandom.hex(4)}", content: 'Oi {{1}}, tudo bem?', channel: nil)
      end

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'send_template', 'action_value' => template.id,
                        'action_variables' => { '1' => '{{contact.name}}' } }]
        })
      end

      it 'sends the template with the placeholder resolved from the contact' do
        expect { service.perform }.to change { conversation.messages.count }.by(1)
        expect(conversation.messages.order(:created_at).last.content).to eq("Oi #{contact.name}, tudo bem?")
      end

      context 'when the resolved variable is blank and a fallback is provided' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'send_template', 'action_value' => template.id,
                          'action_variables' => { '1' => '{{contact.identifier}}' },
                          'action_variable_fallbacks' => { '1' => 'amigo' } }]
          })
        end

        it 'falls back to the configured text' do
          service.perform
          expect(conversation.messages.order(:created_at).last.content).to eq('Oi amigo, tudo bem?')
        end
      end
    end

    # EVO: stage automation gains 4 actions mirroring the account-level canvas
    # automation handlers (AutomationRules::MessageActionHandlers /
    # ConversationActionHandlers), adapted to the single-string action_value
    # stage automation rules carry.
    context 'with send_canned_response action' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }
      let(:canned) { CannedResponse.create!(content: 'Hello from canned!', short_code: "cr-#{SecureRandom.hex(4)}") }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'send_canned_response', 'action_value' => canned.id }]
        })
      end

      it 'sends the canned response content as a message' do
        expect { service.perform }.to change { conversation.messages.count }.by(1)
        expect(conversation.messages.order(:created_at).last.content).to eq('Hello from canned!')
      end

      context 'when the canned response id does not exist' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'send_canned_response', 'action_value' => SecureRandom.uuid }]
          })
        end

        it 'logs a warning and does not send a message' do
          allow(Rails.logger).to receive(:warn)
          expect { service.perform }.not_to change { conversation.messages.count }
          expect(Rails.logger).to have_received(:warn).with(/not found.*send_canned_response/i)
        end
      end
    end

    context 'with send_email_to_team action' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }
      let(:team) { Team.create!(name: "Team-#{SecureRandom.hex(4)}") }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent', 'action' => 'send_email_to_team',
                        'action_value' => { 'team_ids' => [team.id], 'message' => 'Heads up' }.to_json }]
        })
      end

      it 'emails the team about the conversation' do
        mailer = double(deliver_now: true)
        allow(TeamNotifications::AutomationNotificationMailer).to receive(:conversation_creation).and_return(mailer)

        service.perform

        expect(TeamNotifications::AutomationNotificationMailer)
          .to have_received(:conversation_creation).with(conversation, team, 'Heads up')
        expect(mailer).to have_received(:deliver_now)
      end

      context 'when action_value is not valid JSON' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'send_email_to_team', 'action_value' => 'not-json' }]
          })
        end

        it 'logs a warning and does not raise' do
          allow(Rails.logger).to receive(:warn)
          expect { service.perform }.not_to raise_error
          expect(Rails.logger).to have_received(:warn).with(/send_email_to_team/i)
        end
      end
    end

    context 'with send_email_transcript action' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'send_email_transcript', 'action_value' => 'ops@example.com, sales@example.com' }]
        })
      end

      it 'delivers the conversation transcript to each email' do
        delivery = double(deliver_later: true)
        with_proxy = double('with_proxy')
        allow(ConversationReplyMailer).to receive(:with).with(account: nil).and_return(with_proxy)
        allow(with_proxy).to receive(:conversation_transcript).and_return(delivery)

        service.perform

        expect(with_proxy).to have_received(:conversation_transcript).with(conversation, 'ops@example.com')
        expect(with_proxy).to have_received(:conversation_transcript).with(conversation, 'sales@example.com')
        expect(delivery).to have_received(:deliver_later).twice
      end
    end

    context 'with update_custom_attribute action' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      context 'targeting a conversation_attribute' do
        let!(:definition) do
          CustomAttributeDefinition.create!(attribute_display_name: 'Priority Score', attribute_key: 'priority_score',
                                             attribute_display_type: 'text', attribute_model: 'conversation_attribute')
        end

        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent', 'action' => 'update_custom_attribute',
                          'action_value' => { 'custom_attribute_key' => 'priority_score',
                                               'custom_attribute_model' => 'conversation_attribute',
                                               'custom_attribute_value' => 'high' }.to_json }]
          })
        end

        it 'sets the custom attribute on the conversation' do
          service.perform
          expect(conversation.reload.custom_attributes['priority_score']).to eq('high')
        end
      end

      context 'targeting a pipeline_item_attribute' do
        let!(:definition) do
          CustomAttributeDefinition.create!(attribute_display_name: 'Deal Size', attribute_key: 'deal_size',
                                             attribute_display_type: 'text', attribute_model: 'pipeline_item_attribute')
        end

        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent', 'action' => 'update_custom_attribute',
                          'action_value' => { 'custom_attribute_key' => 'deal_size',
                                               'custom_attribute_model' => 'pipeline_item_attribute',
                                               'custom_attribute_value' => '5000' }.to_json }]
          })
        end

        it 'sets the custom field on the pipeline item' do
          service.perform
          expect(pipeline_item.reload.custom_fields['deal_size']).to eq('5000')
        end
      end

      context 'when action_value is not valid JSON' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'update_custom_attribute', 'action_value' => 'not-json' }]
          })
        end

        it 'logs a warning and does not raise' do
          allow(Rails.logger).to receive(:warn)
          expect { service.perform }.not_to raise_error
          expect(Rails.logger).to have_received(:warn).with(/update_custom_attribute/i)
        end
      end
    end
  end
end
