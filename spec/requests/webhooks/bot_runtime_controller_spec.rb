require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Webhooks::BotRuntime Flow', type: :request do
  include ActiveJob::TestHelper

  let!(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let!(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let!(:agent_bot) { AgentBot.create!(name: 'Test Bot', outgoing_url: 'http://bot.runtime/events') }
  let!(:agent_bot_inbox) { AgentBotInbox.create!(inbox: inbox, agent_bot: agent_bot) }
  let!(:contact) { Contact.create!(name: 'Spec Contact', email: 'spec@example.com') }
  let!(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let!(:message) { Message.create!(conversation: conversation, inbox: inbox, sender: contact, content: 'Hello', message_type: :incoming) }

  before do
    allow(BotRuntime::Config).to receive(:secret).and_return('secret123')
    allow(BotRuntime::Config).to receive(:url).and_return('http://bot.runtime')
    allow(BotRuntime::Config).to receive(:timeout).and_return(5)
  end

  describe 'Full Flow: Delegation to Bot and Postback' do
    it 'dispatches typing_on, sends event, and dispatches typing_off on postback' do
      # 1. We expect dispatcher to receive typing_on
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        'conversation.typing_on',
        any_args
      ).and_call_original

      # We also expect other dispatches (like message creation), so we allow them
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original

      # 2. We mock the HTTP request to the bot runtime
      stub_request(:post, 'http://bot.runtime/events')
        .with(headers: { 'X-Bot-Runtime-Secret' => 'secret123' })
        .to_return(status: 202, body: { status: 'accepted' }.to_json)

      # Trigger the delegation
      perform_enqueued_jobs do
        BotRuntime::DelegationService.new(agent_bot, message, conversation).delegate
      end

      # Verify the request was made
      expect(WebMock).to have_requested(:post, 'http://bot.runtime/events').once

      # 3. Simulate bot runtime postback and expect typing_off to be dispatched
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        'conversation.typing_off',
        any_args
      ).and_call_original

      post "/webhooks/bot_runtime/postback/#{conversation.display_id}",
           params: { content: 'Hello from Bot!' },
           headers: { 'X-Bot-Runtime-Secret' => 'secret123' }

      expect(response).to have_http_status(:ok)
      expect(conversation.messages.last.content).to eq('Hello from Bot!')
      expect(conversation.messages.last.sender).to eq(agent_bot)
    end
  end

  describe 'Error Flow: SendEventJob fails' do
    it 'dispatches typing_off after retries are exhausted' do
      # 1. typing_on dispatched
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        'conversation.typing_on',
        any_args
      ).and_call_original

      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original

      # 2. Mock BotRuntime::Client to raise CircuitOpenError (simulating discarded job)
      allow_any_instance_of(BotRuntime::Client).to receive(:send_event)
        .and_raise(BotRuntime::CircuitBreaker::CircuitOpenError.new('Circuit open'))

      # Expect typing_off to be dispatched
      expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
        'conversation.typing_off',
        any_args
      ).and_call_original

      perform_enqueued_jobs do
        BotRuntime::DelegationService.new(agent_bot, message, conversation).delegate
      end
    end
  end
end
