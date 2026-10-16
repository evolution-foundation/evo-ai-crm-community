# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBotInbox do
  describe '#set_default_configurations' do
    it 'defaults status to active when status is not set' do
      agent_bot_inbox = described_class.new

      agent_bot_inbox.send(:set_default_configurations)

      expect(agent_bot_inbox.status).to eq('active')
    end

    it 'does not override an explicit status' do
      agent_bot_inbox = described_class.new(status: :inactive)

      agent_bot_inbox.send(:set_default_configurations)

      expect(agent_bot_inbox.status).to eq('inactive')
    end
  end

  # CRM-212: the log only said "does not match configuration criteria
  # (status/labels/ignored_labels)" — which of the three rejected, and with
  # which values, was invisible. These lock the reason down.
  describe '#processing_block_reason' do
    # Tag names that look like UUIDs are already CRM Label ids, so the real
    # resolution runs here without touching the labels table.
    let(:ignored_label) { '11111111-1111-4111-8111-111111111111' }
    let(:allowed_label) { '22222222-2222-4222-8222-222222222222' }

    def conversation(status: 'open', labels: [])
      instance_double(Conversation, status: status, label_list: labels, contact: nil)
    end

    it 'names the status rule and the configured list when the status is not allowed' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: ['pending'])

      reason = agent_bot_inbox.processing_block_reason(conversation)

      expect(reason).to include('status "open"')
      expect(reason).to include('allowed_conversation_statuses=["pending"]')
    end

    # The default is the case that bites in production: nothing is configured, so
    # only `pending` passes and the bot goes quiet as soon as an agent takes the
    # conversation (status becomes `open`).
    it 'spells out that the default is pending-only when nothing is configured' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: [])

      reason = agent_bot_inbox.processing_block_reason(conversation)

      expect(reason).to include('allowed_conversation_statuses=[] (default: pending only)')
    end

    it 'reports the ignored label before any other rule' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: ['open'], ignored_label_ids: [ignored_label])

      reason = agent_bot_inbox.processing_block_reason(conversation(labels: [ignored_label]))

      expect(reason).to include('ignored_label present')
    end

    it 'reports the allowed-label rule when the conversation carries none of them' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: ['open'], allowed_label_ids: [allowed_label])

      reason = agent_bot_inbox.processing_block_reason(conversation(labels: [ignored_label]))

      expect(reason).to include('no allowed label')
    end

    it 'returns nil when the conversation carries an allowed label and an allowed status' do
      agent_bot_inbox = described_class.new(allowed_conversation_statuses: %w[pending open], allowed_label_ids: [allowed_label])

      expect(agent_bot_inbox.processing_block_reason(conversation(labels: [allowed_label]))).to be_nil
    end

    it 'keeps should_process_conversation? in sync with the reason' do
      blocked = described_class.new(allowed_conversation_statuses: ['pending'])
      eligible = described_class.new(allowed_conversation_statuses: ['open'])

      expect(blocked.should_process_conversation?(conversation)).to be(false)
      expect(eligible.should_process_conversation?(conversation)).to be(true)
    end
  end

  describe '#group_mention_block_reason' do
    let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution_go') }
    let(:matcher) { instance_double(Whatsapp::EvolutionGoBotMentionMatcher, mentioned?: false) }

    before do
      allow(Whatsapp::EvolutionGoBotMentionMatcher).to receive(:new).with(channel).and_return(matcher)
    end

    def message(group: true, mentions: nil, channel: self.channel)
      contact = instance_double(Contact, group?: group)
      attrs = mentions ? { 'mentioned_jids' => mentions } : {}
      instance_double(Message, content_attributes: attrs,
                               conversation: instance_double(Conversation, contact: contact),
                               inbox: instance_double(Inbox, channel: channel))
    end

    it 'blocks a group message that does not mention the inbox number' do
      reason = described_class.new(group_mention_required: true).group_mention_block_reason(message)

      expect(reason).to include('group message without mention')
    end

    it 'passes a group message that mentions the inbox number' do
      allow(matcher).to receive(:mentioned?).with(['5571991589983@s.whatsapp.net']).and_return(true)

      reason = described_class.new(group_mention_required: true)
                              .group_mention_block_reason(message(mentions: ['5571991589983@s.whatsapp.net']))

      expect(reason).to be_nil
    end

    it 'passes every group message when the option is off' do
      expect(described_class.new(group_mention_required: false).group_mention_block_reason(message)).to be_nil
    end

    it 'ignores one-to-one conversations' do
      expect(described_class.new(group_mention_required: true).group_mention_block_reason(message(group: false))).to be_nil
    end

    it 'ignores providers other than Evolution Go' do
      other = instance_double(Channel::Whatsapp, provider: 'evolution')

      expect(described_class.new(group_mention_required: true).group_mention_block_reason(message(channel: other))).to be_nil
    end

    it 'defaults the option to on for new records' do
      expect(described_class.new.group_mention_required).to be(true)
    end
  end
end
