# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageMessageActions do
  let(:host) { Class.new { include Pipelines::StageMessageActions }.new }
  let(:pipeline_owner) { User.create!(name: 'Pipeline Owner', email: "owner-#{SecureRandom.hex(4)}@test.com") }
  let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'custom', created_by: pipeline_owner) }
  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage A', position: 1) }
  let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:pipeline_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact) }

  after { Current.user = nil }

  describe '#create_pipeline_task' do
    it "falls back to the pipeline's own creator, not an arbitrary global user (EVO-659)" do
      # Created before pipeline_owner, so it would be User.first globally — but has
      # no relationship to this pipeline. The old fallback (Current.user || User.first)
      # credited the task to whichever user happens to sort first account-wide, a
      # stranger on a shared install.
      stranger = User.create!(name: 'Stranger', email: "stranger-#{SecureRandom.hex(4)}@test.com")
      expect(User.first).to eq(stranger)

      Current.user = nil
      host.send(:create_pipeline_task, pipeline_item, 'Follow up')

      task = pipeline_item.tasks.last
      expect(task.created_by).to eq(pipeline_owner)
      expect(task.created_by).not_to eq(stranger)
    end

    it 'prefers Current.user when one is present' do
      current = User.create!(name: 'Current Agent', email: "current-#{SecureRandom.hex(4)}@test.com")

      Current.user = current
      host.send(:create_pipeline_task, pipeline_item, 'Follow up')

      expect(pipeline_item.tasks.last.created_by).to eq(current)
    end
  end

  describe '#send_ai_message' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    let(:router_bot) do
      AgentBot.create!(name: 'router', outgoing_url: 'https://router.example', bot_provider: 'evo_ai',
                        api_key: 'router-key')
    end
    let(:uk_subagent) do
      AgentBot.create!(name: 'uk_subagent', outgoing_url: 'https://uk.example', bot_provider: 'evo_ai',
                        api_key: 'uk-key',
                        bot_config: { 'pipeline_rules' => [{ 'pipelineId' => pipeline.id.to_s }] })
    end

    before do
      AgentBotInbox.create!(inbox: inbox, agent_bot: router_bot)
      PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    end

    def dispatched_bot_for(**send_ai_message_kwargs)
      dispatched = nil
      allow(AgentBots::HttpRequestService).to receive(:new) do |bot, _payload|
        dispatched = bot
        double(perform: 'ok')
      end

      host.send(:send_ai_message, conversation, **send_ai_message_kwargs)
      dispatched
    end

    it "defaults to the inbox's own bot when nothing else matches" do
      expect(dispatched_bot_for).to eq(router_bot)
    end

    it "prefers a bot whose pipeline_rules match the given pipeline_id over the inbox's own bot" do
      uk_subagent

      expect(dispatched_bot_for(pipeline_id: pipeline.id)).to eq(uk_subagent)
    end

    it 'prefers an explicitly selected bot over both the pipeline match and the inbox bot' do
      uk_subagent
      explicit_bot = AgentBot.create!(name: 'explicit', outgoing_url: 'https://explicit.example', bot_provider: 'evo_ai',
                                       api_key: 'explicit-key')

      result = dispatched_bot_for(pipeline_id: pipeline.id, explicit_agent_bot_id: explicit_bot.id)

      expect(result).to eq(explicit_bot)
    end
  end
end
