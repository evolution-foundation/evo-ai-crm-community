# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineStage, type: :model do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:pipeline) { Pipeline.create!(name: 'P', pipeline_type: 'custom', created_by: user) }

  def whatsapp_cloud_channel(with_inbox: true)
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: "+1555#{SecureRandom.hex(3)}")
    channel.save!(validate: false)
    Inbox.create!(name: "WA-#{SecureRandom.hex(3)}", channel: channel) if with_inbox
    channel
  end

  def rule_for(template_id)
    { 'id' => SecureRandom.uuid, 'trigger' => 'label_added', 'trigger_value' => 'x',
      'action' => 'send_template', 'action_value' => template_id }
  end

  def stage_with_rule(template_id)
    PipelineStage.new(pipeline: pipeline, name: 'S', position: 1,
                       automation_rules: { 'rules' => [rule_for(template_id)] })
  end

  # EVO: a stage rule that sends a WhatsApp Cloud template is unusable if that template's
  # channel/inbox is gone or disconnected — reject the save instead of silently persisting
  # a rule that will fail (or misfire) the next time it fires.
  describe 'send_template WhatsApp Cloud channel validation' do
    it 'is valid when the template has no channel at all (global template)' do
      template = MessageTemplate.create!(name: "g-#{SecureRandom.hex(4)}", content: 'hi')

      expect(stage_with_rule(template.id)).to be_valid
    end

    it 'is valid when the WhatsApp Cloud template has an active channel + inbox' do
      channel = whatsapp_cloud_channel
      template = MessageTemplate.create!(name: "wac-#{SecureRandom.hex(4)}", content: 'hi', channel: channel)

      expect(stage_with_rule(template.id)).to be_valid
    end

    it 'is invalid when the WhatsApp Cloud template channel has no inbox' do
      channel = whatsapp_cloud_channel(with_inbox: false)
      template = MessageTemplate.create!(name: "wac-#{SecureRandom.hex(4)}", content: 'hi', channel: channel)

      stage = stage_with_rule(template.id)

      expect(stage).not_to be_valid
      expect(stage.errors[:automation_rules]).to be_present
    end

    it 'is invalid when the WhatsApp Cloud channel requires reauthorization' do
      channel = whatsapp_cloud_channel
      channel.prompt_reauthorization!
      template = MessageTemplate.create!(name: "wac-#{SecureRandom.hex(4)}", content: 'hi', channel: channel)

      expect(stage_with_rule(template.id)).not_to be_valid
    end

    it 'ignores rules whose action_value does not resolve to any template' do
      expect(stage_with_rule(SecureRandom.uuid)).to be_valid
    end

    # EVO: a channel can go bad (disconnected / inbox deleted) long after the rule was saved.
    # Re-running this check on every unrelated save (rename, reorder, stage_type change) would
    # make the stage permanently unsavable for anything until an operator fixes the channel —
    # it must only fire when automation_rules itself is part of the save.
    it 'stays saveable for unrelated attribute changes once the channel later becomes invalid' do
      channel = whatsapp_cloud_channel
      template = MessageTemplate.create!(name: "wac-#{SecureRandom.hex(4)}", content: 'hi', channel: channel)
      stage = stage_with_rule(template.id)
      stage.save!

      # The channel goes bad AFTER the rule was already persisted.
      channel.prompt_reauthorization!

      stage.name = 'Renamed'
      expect(stage).to be_valid
      expect { stage.save! }.not_to raise_error
      expect(stage.reload.name).to eq('Renamed')
    end
  end
end
