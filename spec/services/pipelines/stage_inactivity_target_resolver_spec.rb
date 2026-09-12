# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageInactivityTargetResolver do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:contact) do
    Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@test.com", phone_number: '+15551234567')
  end
  let(:pipeline) { Pipeline.create!(name: 'P', pipeline_type: 'custom', created_by: user) }
  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'S', position: 1) }
  let!(:pipeline_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact) }

  subject(:resolver) { described_class.new(pipeline_item.reload) }

  def whatsapp_cloud_channel
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: "+1555#{SecureRandom.hex(3)}")
    channel.save!(validate: false)
    channel
  end

  # EVO: a send_template rule's MessageTemplate already names exactly one channel/inbox
  # (MessageTemplate#channel_required_for_whatsapp_cloud) — resolution should use it
  # directly instead of a generic contactable-inbox scan that could pick the wrong inbox.
  context 'when the send_template action targets a WhatsApp Cloud template' do
    let(:channel) { whatsapp_cloud_channel }
    let!(:inbox) { Inbox.create!(name: 'WA Cloud', channel: channel) }
    let(:template) { MessageTemplate.create!(name: "tpl-#{SecureRandom.hex(4)}", content: 'Oi {{1}}', channel: channel) }

    # A generic API inbox also exists, to prove the resolver does not fall back to the scan.
    let!(:other_inbox) { Inbox.create!(name: 'API', channel: Channel::Api.create!) }

    it 'creates the conversation on the inbox that owns the template channel' do
      result = resolver.resolve('send_template', template.id)

      expect(result).not_to be_nil
      expect(result.conversation.inbox_id).to eq(inbox.id)
      expect(result.created).to be true
    end
  end

  context 'when the send_template action targets a template with no channel' do
    let!(:inbox) { Inbox.create!(name: 'API only', channel: Channel::Api.create!) }
    let(:template) { MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'Oi {{1}}') }

    it 'falls back to the generic contactable inbox scan' do
      result = resolver.resolve('send_template', template.id)

      expect(result).not_to be_nil
      expect(result.conversation.inbox_id).to eq(inbox.id)
    end
  end

  context 'when the action is not send_template' do
    let(:channel) { whatsapp_cloud_channel }
    let!(:inbox) { Inbox.create!(name: 'WA Cloud', channel: channel) }
    let(:template) { MessageTemplate.create!(name: "tpl-#{SecureRandom.hex(4)}", content: 'Oi {{1}}', channel: channel) }

    # The template-channel shortcut is gated on action == 'send_template'; falling through to
    # the generic scan lands on the same (non-free-text) WhatsApp Cloud inbox, which cannot
    # originate a free-text conversation, so no target is created.
    it 'does not use the template channel shortcut' do
      result = resolver.resolve('send_direct_message', template.id)

      expect(result).to be_nil
    end
  end
end
