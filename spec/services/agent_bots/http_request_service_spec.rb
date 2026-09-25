# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::HttpRequestService do
  let(:agent_bot) { AgentBot.create!(name: 'Bot', outgoing_url: 'https://bot.example') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:payload) do
    { event: 'message_created', message_type: 'incoming', content: 'hi',
      conversation: { id: conversation.id } }
  end
  let(:service) { described_class.new(agent_bot, payload) }

  def jsonrpc_params
    service.send(:build_params)
  end

  it 'omits memorySessionEpoch and memoryMinTimestamp for a conversation that was never reopened' do
    params = jsonrpc_params

    expect(params[:contextId]).to eq(conversation.id.to_s)
    expect(params[:metadata]).not_to have_key(:memorySessionEpoch)
    expect(params[:metadata]).not_to have_key(:memoryMinTimestamp)
  end

  it 'includes memorySessionEpoch and memoryMinTimestamp after a resolved -> reopened transition' do
    conversation.update!(status: :resolved)
    travel_to(Time.utc(2026, 9, 25, 12, 0, 0)) { conversation.update!(status: :open) }
    conversation.reload

    params = jsonrpc_params

    expect(params[:contextId]).to eq("#{conversation.id}_r1")
    expect(params[:metadata][:memorySessionEpoch]).to eq(1)
    expect(params[:metadata][:memoryMinTimestamp]).to eq('2026-09-25T12:00:00Z')
  end
end
