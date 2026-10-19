# Runs the real application classes with in-memory collaborators. No live DB,
# Redis, Meta, Mautic, or customer channel is used by this safety contract.
ENV['RAILS_ENV'] = 'test'
require_relative '../../../config/environment'

# Schema-free boundary doubles keep this suite runnable without a database.
# rubocop:disable RSpec/VerifiedDoubles

RSpec.describe Instagram::AmhSafety do
  let(:inbox) { double('inbox', id: 'qa-instagram') }
  let(:conversation) { double('conversation', inbox: inbox) }
  let(:contact) { double('contact') }
  let(:message) do
    double('message', inbox: inbox, outgoing?: true, template?: false,
                      content_attributes: {}, additional_attributes: {}, sender: nil)
  end

  around do |example|
    original = ENV.to_h.slice('INSTAGRAM_AMH_INBOX_IDS', 'INSTAGRAM_AMH_RECEPTION_ENABLED')
    ENV['INSTAGRAM_AMH_INBOX_IDS'] = ' qa-instagram, qa-second '
    ENV.delete('INSTAGRAM_AMH_RECEPTION_ENABLED')
    example.run
  ensure
    %w[INSTAGRAM_AMH_INBOX_IDS INSTAGRAM_AMH_RECEPTION_ENABLED].each { |key| ENV.delete(key) }
    ENV.update(original)
  end

  it 'receives independently while automatic outbound stays blocked' do
    expect(described_class.reception_enabled?(inbox)).to be true
    expect(described_class.blocked_inbox?(inbox)).to be true
    ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] = 'false'
    expect(described_class.reception_enabled?(inbox)).to be false
    expect(described_class.blocked_inbox?(inbox)).to be true
    expect(described_class.reception_enabled?(double(id: 'other'))).to be true
  end

  it 'does not change other inboxes or unconfigured installations' do
    expect(described_class.blocked_inbox?(double(id: 'other'))).to be false
    ENV.delete('INSTAGRAM_AMH_INBOX_IDS')
    expect(described_class.blocked_message?(message)).to be false
  end

  it 'allows human replies but blocks bots, campaigns and rule provenance' do
    expect(described_class.blocked_message?(message)).to be true
    allow(message).to receive(:sender).and_return(User.allocate)
    expect(described_class.blocked_message?(message)).to be false
    allow(message).to receive(:content_attributes).and_return('automation_rule_id' => 'rule')
    expect(described_class.blocked_message?(message)).to be true
    allow(message).to receive(:content_attributes).and_return({})
    allow(message).to receive(:additional_attributes).and_return('campaign_id' => 'campaign')
    expect(described_class.blocked_message?(message)).to be true
  end

  it 'preserves inbound messages even without email' do
    allow(message).to receive(:outgoing?).and_return(false)
    expect(described_class.blocked_message?(message)).to be false
  end

  it 'recognizes serialized and legacy bot webhook scopes' do
    [{ inbox_id: inbox.id }, { 'inbox' => { 'id' => inbox.id } },
     { conversation: { inbox_id: inbox.id } }, { metadata: { inboxId: inbox.id } }].each do |payload|
      expect(described_class.blocked_payload?(payload)).to be true
    end
    expect(described_class.blocked_payload?(inbox_id: 'other')).to be false
  end

  it 'blocks contact-only automation from its durable inbox mapping' do
    scope = double('contact inbox scope')
    allow(contact).to receive(:contact_inboxes).and_return(scope)
    allow(scope).to receive(:exists?).with(inbox_id: described_class.inbox_ids).and_return(true)
    allow(Contact).to receive(:find_by).with(id: 'contact').and_return(contact)
    expect(described_class.blocked_payload?(event: 'contact_created', id: 'contact')).to be true
    expect(described_class.blocked_payload?('event' => 'contact_updated', 'id' => 'contact')).to be true
    expect(described_class.blocked_payload?('contactId' => 'contact', 'eventName' => 'contact.created')).to be true
    expect(EvoFlow::Client).not_to receive(:new)
    EvoFlow::PublishEventWorker.new.perform('/events/identify', { 'contactId' => 'contact' })
  end

  it 'blocks old SendReply jobs before selecting any transport, repeatedly' do
    allow(Message).to receive(:find).with('queued').and_return(message)
    expect(message).not_to receive(:conversation)
    2.times { SendReplyJob.new.perform('queued') }
  end

  it 'blocks both direct and Messenger transport paths before any HTTP or token accessor' do
    allow(message).to receive(:conversation).and_return(conversation)
    allow(conversation).to receive(:contact).and_return(contact)
    expect(HTTParty).not_to receive(:post)
    [Instagram::SendOnInstagramService, Instagram::Messenger::SendOnInstagramService].each do |klass|
      klass.new(message: message).send(:perform_reply)
    end
  end

  it 'does not dispatch queued bot or generic webhook jobs, including retries' do
    expect(Webhooks::Trigger).not_to receive(:execute)
    expect(BotRuntime::Client).not_to receive(:new)
    2.times do
      WebhookJob.new.perform('https://invalid.example', { 'inbox' => { 'id' => inbox.id } })
      AgentBots::WebhookJob.new.perform('https://invalid.example', { inbox_id: inbox.id })
      BotRuntime::SendEventJob.new.perform('metadata' => { 'inboxId' => inbox.id })
    end
  end

  it 'blocks rule execution before actions, including canvas flows' do
    allow(conversation).to receive(:reload).and_return(conversation)
    rule = double('rule')
    expect(rule).not_to receive(:actions)
    expect(rule).not_to receive(:mode)
    AutomationRules::ActionService.new(rule, nil, conversation).perform
    AutomationRules::FlowExecutionService.new(rule, nil, conversation).perform
  end

  it 'blocks forced AI replies, delayed segments and inactivity before any write or enqueue' do
    bot = double('bot')
    expect(bot).not_to receive(:bot_config)
    expect(conversation).not_to receive(:messages)
    AgentBots::MessageCreator.new(bot).create_bot_reply('qa', conversation, force: true)
    AgentBots::SegmentedMessageCreator.new(bot).create_messages(['qa'], conversation, force: true)
    AgentBots::SegmentedMessageCreator.new(bot).process_segment_message('qa', conversation)
    AgentBots::InactivityActionsService.new(conversation, bot).process
    BotRuntime::DelegationService.new(bot, message, conversation).delegate
  end

  it 'blocks the bot listener before bot lookup or moderation' do
    expect(inbox).not_to receive(:agent_bot_inbox)
    expect(AgentBotListener.instance.send(:connected_agent_bot_exist?, inbox)).to be false
  end

  it 'preserves the transport path for a manual reply' do
    allow(message).to receive(:sender).and_return(User.allocate)
    allow(message).to receive(:conversation).and_return(conversation)
    allow(conversation).to receive(:contact).and_return(contact)
    allow(message).to receive(:attachments).and_return([])
    allow(message).to receive(:content).and_return('qa')
    service = Instagram::SendOnInstagramService.new(message: message)
    expect(service).to receive(:send_content).once
    service.send(:perform_reply)
  end

  it 'processes a synthetic inbound through contact lookup and message creation with zero outbound' do
    channel = double('channel', reauthorization_required?: false)
    allow(inbox).to receive(:channel).and_return(channel)
    service = Instagram::BaseMessageText.new({}, channel)
    service.instance_variable_set(:@inbox, inbox)
    service.instance_variable_set(:@contact_inbox, double(id: 'qa-contact-inbox'))
    allow(service).to receive(:instagram_and_contact_ids).and_return(%w[qa-account qa-social])
    allow(service).to receive(:inbox_channel)
    allow(service).to receive(:message_is_deleted?).and_return(false)
    allow(service).to receive(:contacts_first_message?).and_return(true)
    expect(service).to receive(:ensure_contact).with('qa-social').once
    expect(service).to receive(:create_message).once.and_return(:persisted_by_existing_builder)
    expect(HTTParty).not_to receive(:post)
    expect(Webhooks::Trigger).not_to receive(:execute)
    expect(service.perform).to eq(:persisted_by_existing_builder)
  end

  it 'pauses scoped inbound before profile lookup or any persistence' do
    ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] = 'false'
    channel = double('channel')
    service = Instagram::BaseMessageText.new({}, channel)
    service.instance_variable_set(:@inbox, inbox)
    allow(service).to receive(:instagram_and_contact_ids).and_return(%w[qa-account qa-social])
    allow(service).to receive(:inbox_channel)
    expect(channel).not_to receive(:reauthorization_required?)
    expect(service).not_to receive(:ensure_contact)
    expect(service).not_to receive(:create_message)
    service.perform
  end

  it 'preserves webhook dispatch and the pipeline rule for an unrelated inbox' do
    payload = { inbox_id: 'other', event: 'automation_event.pipeline_stage_updated' }
    expect(Webhooks::Trigger).to receive(:execute).with('https://invalid.example', payload, :account_webhook).once
    WebhookJob.new.perform('https://invalid.example', payload)
    allow(conversation).to receive(:inbox).and_return(double(id: 'other'))
    allow(conversation).to receive(:reload).and_return(conversation)
    rule = double('rule', actions: [])
    expect(rule).to receive(:actions).once.and_return([])
    AutomationRules::ActionService.new(rule, nil, conversation).perform
  end

  it 'blocks direct transport entry points and AI HTTP consumers without touching credentials' do
    allow(message).to receive(:conversation).and_return(conversation)
    allow(conversation).to receive(:contact).and_return(contact)
    expect(HTTParty).not_to receive(:post)
    [Instagram::SendOnInstagramService, Instagram::Messenger::SendOnInstagramService].each do |klass|
      klass.new(message: message).send(:send_message, {})
    end
    bot = double('bot')
    expect(bot).not_to receive(:outgoing_url)
    [AgentBots::HttpRequestService, AgentBots::N8nRequestService].each do |klass|
      klass.new(bot, { 'conversation' => { 'inbox_id' => inbox.id } }).perform
    end
  end
end

# rubocop:enable RSpec/VerifiedDoubles
