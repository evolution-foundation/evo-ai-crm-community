# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageInactivityActionsService do
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

  subject(:service) { described_class.new(pipeline_item.reload) }

  def set_rule(minutes:, base:, action: 'send_direct_message', action_value: 'Ainda por aqui?', id: SecureRandom.uuid,
               ai_message: nil, action_variables: nil, action_variable_fallbacks: nil)
    rule = {
      'id' => id, 'trigger' => 'inactivity',
      'trigger_value' => { 'minutes' => minutes, 'base' => base },
      'action' => action, 'action_value' => action_value
    }
    rule['ai_message'] = ai_message if ai_message
    rule['action_variables'] = action_variables if action_variables
    rule['action_variable_fallbacks'] = action_variable_fallbacks if action_variable_fallbacks
    stage_a.update!(automation_rules: { 'rules' => [rule] })
    rule
  end

  describe '#process' do
    context 'AC2 — stage_stagnation base, direct message' do
      before { set_rule(minutes: 30, base: 'stage_stagnation') }

      it 'does NOT fire before the threshold' do
        # entry movement just created → ~0 min in stage
        expect { service.process }.not_to change(StageInactivityExecution, :count)
      end

      it 'fires once after the threshold and records the execution' do
        pipeline_item.stage_movements.update_all(created_at: 31.minutes.ago)
        expect { service.process }.to change(StageInactivityExecution, :count).by(1)
      end
    end

    context 'AC13 — stagnation clock counts from current-stage entry, not entered_at' do
      before do
        set_rule(minutes: 30, base: 'stage_stagnation')
        # item has been in the pipeline for days, but just entered this stage
        pipeline_item.update_column(:entered_at, 3.days.ago)
        pipeline_item.stage_movements.update_all(created_at: 5.minutes.ago)
      end

      it 'does NOT fire (only 5 min in current stage)' do
        expect { service.process }.not_to change(StageInactivityExecution, :count)
      end
    end

    context 'AC1/AC3 — no_customer_reply base + idempotency' do
      before do
        set_rule(minutes: 5, base: 'no_customer_reply')
        Message.create!(account_id: nil, inbox: inbox, conversation: conversation, contact: contact,
                        message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
      rescue StandardError
        # account_id may be required differently in single-tenant; fall back
        conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi',
                                      created_at: 6.minutes.ago)
      end

      it 'fires once' do
        expect { service.process }.to change(StageInactivityExecution, :count).by(1)
      end

      it 'does not fire again on a second run (idempotent)' do
        service.process
        expect { described_class.new(pipeline_item.reload).process }
          .not_to change(StageInactivityExecution, :count)
      end
    end

    context 'AC13b — no_customer_reply on a lead with no conversation is a no-op' do
      let!(:lead_item) do
        PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage_a, contact: contact)
      end

      it 'skips (no conversation to measure)' do
        set_rule(minutes: 1, base: 'no_customer_reply')
        svc = described_class.new(lead_item.reload)
        expect { svc.process }.not_to change(StageInactivityExecution, :count)
      end
    end
  end

  describe 'reset semantics' do
    it 'AC5 — moving stages wipes stage_stagnation executions for the item' do
      StageInactivityExecution.create!(pipeline_item: pipeline_item, pipeline_stage_id: stage_a.id,
                                       rule_id: 'r1', base: 'stage_stagnation', action: 'send_direct_message',
                                       executed_at: Time.current)
      pipeline_item.move_to_stage(stage_b)
      expect(StageInactivityExecution.for_item(pipeline_item.id).where(base: 'stage_stagnation')).to be_empty
    end

    it 'base-specific reset does not cross-delete' do
      StageInactivityExecution.create!(pipeline_item: pipeline_item, pipeline_stage_id: stage_a.id,
                                       rule_id: 'reply1', base: 'no_customer_reply', action: 'send_direct_message',
                                       executed_at: Time.current)
      StageInactivityExecution.create!(pipeline_item: pipeline_item, pipeline_stage_id: stage_a.id,
                                       rule_id: 'stag1', base: 'stage_stagnation', action: 'send_direct_message',
                                       executed_at: Time.current)
      StageInactivityExecution.reset_for_item(pipeline_item.id, base: 'no_customer_reply')
      remaining = StageInactivityExecution.for_item(pipeline_item.id).pluck(:base)
      expect(remaining).to eq(['stage_stagnation'])
    end
  end

  # EVO: send_template inactivity rules may carry action_variables/action_variable_fallbacks
  # so a WhatsApp template's {{1}}-style placeholders get filled instead of sent literally
  # (mirrors AutomationRules::MessageActionHandlers#resolve_template_params).
  describe '#process — send_template with action_variables' do
    let(:template) do
      MessageTemplate.create!(name: "greet-#{SecureRandom.hex(4)}", content: 'Oi {{1}}, tudo bem?', channel: nil)
    end

    before do
      set_rule(minutes: 5, base: 'no_customer_reply', action: 'send_template', action_value: template.id,
                action_variables: { '1' => '{{contact.name}}' })
      conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
    end

    it 'fills the template placeholder from the contact name' do
      service.process
      message = conversation.messages.order(:created_at).last
      expect(message.content).to eq("Oi #{contact.name}, tudo bem?")
    end

    context 'when the resolved variable is blank and a fallback is provided' do
      before do
        set_rule(minutes: 5, base: 'no_customer_reply', action: 'send_template', action_value: template.id,
                  action_variables: { '1' => '{{contact.identifier}}' },
                  action_variable_fallbacks: { '1' => 'amigo' })
      end

      it 'falls back to the configured text' do
        service.process
        message = conversation.messages.order(:created_at).last
        expect(message.content).to eq('Oi amigo, tudo bem?')
      end
    end
  end

  # EVO: inactivity gains the same 4 actions as the event-driven stage automation path
  # (mirroring AutomationRules::MessageActionHandlers / ConversationActionHandlers).
  describe '#process — send_canned_response' do
    let(:canned) { CannedResponse.create!(content: 'Ainda por aqui?', short_code: "cr-#{SecureRandom.hex(4)}") }

    before do
      set_rule(minutes: 5, base: 'no_customer_reply', action: 'send_canned_response', action_value: canned.id)
      conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
    end

    it 'sends the canned response content as a message' do
      expect { service.process }.to change { conversation.messages.count }.by(1)
      expect(conversation.messages.order(:created_at).last.content).to eq('Ainda por aqui?')
    end
  end

  describe '#process — send_email_to_team' do
    let(:team) { Team.create!(name: "Team-#{SecureRandom.hex(4)}") }

    before do
      set_rule(minutes: 5, base: 'no_customer_reply', action: 'send_email_to_team',
                action_value: { 'team_ids' => [team.id], 'message' => 'Heads up' }.to_json)
      conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
    end

    it 'emails the team about the conversation' do
      mailer = double(deliver_now: true)
      allow(TeamNotifications::AutomationNotificationMailer).to receive(:conversation_creation).and_return(mailer)

      service.process

      expect(TeamNotifications::AutomationNotificationMailer)
        .to have_received(:conversation_creation).with(conversation, team, 'Heads up')
    end
  end

  describe '#process — send_email_transcript' do
    before do
      set_rule(minutes: 5, base: 'no_customer_reply', action: 'send_email_transcript',
                action_value: 'ops@example.com, sales@example.com')
      conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
    end

    it 'delivers the conversation transcript to each email' do
      delivery = double(deliver_later: true)
      with_proxy = double('with_proxy')
      allow(ConversationReplyMailer).to receive(:with).with(account: nil).and_return(with_proxy)
      allow(with_proxy).to receive(:conversation_transcript).and_return(delivery)

      service.process

      expect(with_proxy).to have_received(:conversation_transcript).with(conversation, 'ops@example.com')
      expect(with_proxy).to have_received(:conversation_transcript).with(conversation, 'sales@example.com')
    end
  end

  describe '#process — update_custom_attribute' do
    let!(:definition) do
      CustomAttributeDefinition.create!(attribute_display_name: 'Deal Size', attribute_key: 'deal_size',
                                         attribute_display_type: 'text', attribute_model: 'pipeline_item_attribute')
    end

    before do
      set_rule(minutes: 5, base: 'no_customer_reply', action: 'update_custom_attribute',
                action_value: { 'custom_attribute_key' => 'deal_size',
                                 'custom_attribute_model' => 'pipeline_item_attribute',
                                 'custom_attribute_value' => '5000' }.to_json)
      conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
    end

    it 'sets the custom field on the pipeline item' do
      service.process
      expect(pipeline_item.reload.custom_fields['deal_size']).to eq('5000')
    end
  end

  # EVO-2201: this path is time-based and fires unattended, so an archived pipeline that
  # kept its inactivity rules would message customers from a board the operator turned off.
  describe 'archived pipeline' do
    before do
      set_rule(minutes: 30, base: 'stage_stagnation')
      pipeline_item.stage_movements.update_all(created_at: 31.minutes.ago)
    end

    it 'does not fire once the pipeline is archived' do
      pipeline.update!(is_active: false)

      expect { described_class.new(pipeline_item.reload).process }
        .not_to change(StageInactivityExecution, :count)
    end

    it 'logs the skip with the pipeline id and the reason' do
      pipeline.update!(is_active: false)
      allow(Rails.logger).to receive(:warn)

      described_class.new(pipeline_item.reload).process

      expect(Rails.logger).to have_received(:warn).with(/#{pipeline.id} is archived/)
    end

    it 'still fires while the pipeline is active' do
      expect { described_class.new(pipeline_item.reload).process }
        .to change(StageInactivityExecution, :count).by(1)
    end
  end
end
