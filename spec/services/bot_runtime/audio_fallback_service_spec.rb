# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::AudioFallbackService do
  let(:incoming_message) do
    instance_double(Message, id: 'incoming-1', incoming?: true, conversation_id: 'conversation-1')
  end
  let(:conversation) { instance_double(Conversation, id: 'conversation-1', messages: messages) }
  let(:inbox) { instance_double(Inbox, agent_bot_inbox: assignment) }
  let(:assignment) { instance_double(AgentBotInbox, active?: true, agent_bot_id: 'bot-1') }
  let(:messages) { instance_double(ActiveRecord::Relation, where: scoped_messages) }
  let(:scoped_messages) { instance_double(ActiveRecord::Relation, exists?: false) }
  let(:agent_bot) { instance_double(AgentBot, id: 'bot-1') }
  let(:creator) { instance_double(AgentBots::MessageCreator) }
  let(:event) { { message_id: 'incoming-1', conversation_id: 'conv-display-1', agent_bot_id: 'bot-1' } }

  before do
    allow(Message).to receive(:find_by).with(id: 'incoming-1').and_return(incoming_message)
    allow(Conversation).to receive(:find_by).with(display_id: 'conv-display-1').and_return(conversation)
    allow(conversation).to receive(:inbox).and_return(inbox)
    allow(AgentBot).to receive(:find_by).with(id: 'bot-1').and_return(agent_bot)
    allow(incoming_message).to receive(:with_lock).and_yield
    allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
  end

  it 'sends one fixed four-minute notice through the CRM agent message path' do
    expect(creator).to receive(:create_bot_reply).with(
      described_class::TOO_LONG_TEXT,
      conversation,
      content_attributes: { described_class::MARKER_KEY => 'incoming-1' }
    ).and_return(instance_double(Message, present?: true))

    expect(described_class.deliver(event, reasons: [:too_long])).to be(true)
  end

  it 'combines failure reasons into one user-facing reply' do
    expect(creator).to receive(:create_bot_reply).with(
      described_class::MIXED_FAILURE_TEXT,
      conversation,
      content_attributes: { described_class::MARKER_KEY => 'incoming-1' }
    ).and_return(instance_double(Message, present?: true))

    described_class.deliver(event, reasons: %i[too_long unavailable])
  end

  it 'does not create another reply when a retry already sent the marked fallback' do
    allow(scoped_messages).to receive(:exists?).and_return(true)

    expect(AgentBots::MessageCreator).not_to receive(:new)
    expect(described_class.deliver(event, reasons: [:too_long])).to be(true)
  end

  it 'finds an existing idempotency marker with the production JSON query' do
    conversation = Conversation.new(id: SecureRandom.uuid)
    incoming = instance_double(Message, id: SecureRandom.uuid)
    outgoing_id = SecureRandom.uuid
    now = Time.current
    Message.connection.execute(
      Message.sanitize_sql_array(
        [
          'INSERT INTO messages (id, conversation_id, inbox_id, message_type, content_attributes, created_at, updated_at) ' \
          'VALUES (?, ?, ?, ?, ?::json, ?, ?)',
          outgoing_id,
          conversation.id,
          SecureRandom.uuid,
          Message.message_types.fetch('outgoing'),
          { described_class::MARKER_KEY => incoming.id.to_s }.to_json,
          now,
          now
        ]
      )
    )

    service = described_class.new(event, [:too_long])

    expect(service.send(:fallback_already_sent?, conversation, incoming)).to be(true)
  ensure
    Message.where(id: outgoing_id).delete_all if outgoing_id
  end

  it 'does not send when the message belongs to a different conversation' do
    allow(incoming_message).to receive(:conversation_id).and_return('other-conversation')

    expect(AgentBots::MessageCreator).not_to receive(:new)
    expect(described_class.deliver(event, reasons: [:too_long])).to be(false)
  end

  it 'does not send when the bot assignment is inactive' do
    allow(assignment).to receive(:active?).and_return(false)

    expect(AgentBots::MessageCreator).not_to receive(:new)
    expect(described_class.deliver(event, reasons: [:too_long])).to be(false)
  end

  it 'uses the ordinary non-forced CRM reply path so human handoff rules remain in force' do
    expect(creator).to receive(:create_bot_reply).with(
      described_class::UNAVAILABLE_TEXT,
      conversation,
      content_attributes: { described_class::MARKER_KEY => 'incoming-1' }
    ).and_return(instance_double(Message, present?: true))

    expect(described_class.deliver(event, reasons: [:unavailable])).to be(true)
  end
end
