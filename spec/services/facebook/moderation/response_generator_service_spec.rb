# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# The moderation reply used to leave through a hand-built Net::HTTP request,
# skipping HttpRequestService#build_http_request — the seam request decorations
# hang on. Skipping it drops the decorated headers and the processor rejects the
# agent-key lookup, so moderation goes silent. These specs pin the delegation
# and the wire contract.
RSpec.describe Facebook::Moderation::ResponseGeneratorService do
  let(:bot) do
    AgentBot.create!(name: "Bot #{SecureRandom.hex(3)}", description: 'bot',
                     outgoing_url: 'https://processor.internal/api/v1/a2a/agent-1',
                     bot_provider: 'evo_ai_provider', api_key: 'inline-key')
  end
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:message) do
    conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'quero saber o preço', sender: contact)
  end
  let(:service) { described_class.new(conversation: conversation, message: message, agent_bot: bot) }

  let(:artifacts_body) do
    { result: { artifacts: [{ parts: [{ 'type' => 'text', 'text' => 'resposta do agente' }] }] } }.to_json
  end

  before do
    allow(AgentBots::CredentialResolution).to receive(:api_key_for).with(bot).and_return('agent-secret')
  end

  describe 'evo_ai_provider' do
    it 'sends the JSON-RPC call through HttpRequestService, with its headers and payload shape' do
      stub = stub_request(:post, bot.outgoing_url).with do |req|
        body = JSON.parse(req.body)
        req.headers['X-Api-Key'] == 'agent-secret' &&
          !req.headers.key?('Authorization') &&
          body['method'] == 'message/send' &&
          body.dig('params', 'contextId') == conversation.id.to_s &&
          body.dig('params', 'message', 'parts', 0, 'text') == message.content &&
          body.dig('params', 'message', 'messageId') == message.id.to_s
      end.to_return(status: 200, body: artifacts_body)

      expect(service.generate).to eq('resposta do agente')
      expect(stub).to have_been_requested
    end

    # Header names alone don't prove the seam: a hand-rolled request can copy them.
    it 'carries the decorations applied in build_http_request' do
      allow_any_instance_of(AgentBots::HttpRequestService)
        .to receive(:build_http_request).and_wrap_original do |original, *args|
          original.call(*args).tap { |request| request['X-Test-Decoration'] = 'applied' }
        end
      stub = stub_request(:post, bot.outgoing_url)
             .with(headers: { 'X-Test-Decoration' => 'applied' })
             .to_return(status: 200, body: artifacts_body)

      expect(service.generate).to eq('resposta do agente')
      expect(stub).to have_been_requested
    end

    it 'prefixes the configured signature' do
      bot.update!(message_signature: 'Equipe X')
      stub_request(:post, bot.outgoing_url).to_return(status: 200, body: artifacts_body)

      expect(service.generate).to eq("Equipe X\n\nresposta do agente")
    end

    it 'returns nil without raising when the processor rejects the call' do
      stub_request(:post, bot.outgoing_url).to_return(status: 401, body: '{"error":"unauthorized"}')

      expect(service.generate).to be_nil
    end
  end

  describe 'other providers' do
    it 'keeps the n8n plain POST untouched' do
      bot.update!(bot_provider: 'n8n')
      stub = stub_request(:post, bot.outgoing_url)
             .with { |req| JSON.parse(req.body)['event'] == 'message_created' }
             .to_return(status: 200, body: { output: 'ok' }.to_json)

      expect(service.generate).to eq('ok')
      expect(stub).to have_been_requested
    end

    # The bot_provider enum reader returns names ('webhook_provider'), so the
    # service's 'webhook' case never matches and these bots take the evo_ai
    # path — pre-existing routing this refactor keeps as is.
    it 'routes a webhook_provider bot through the JSON-RPC service path' do
      bot.update!(bot_provider: 'webhook')
      stub = stub_request(:post, bot.outgoing_url)
             .with { |req| JSON.parse(req.body)['method'] == 'message/send' }
             .to_return(status: 200, body: artifacts_body)

      expect(service.generate).to eq('resposta do agente')
      expect(stub).to have_been_requested
    end
  end

  describe AgentBots::HttpRequestService do
    it 'execute_request is a no-op without an outgoing_url' do
      bot.update!(outgoing_url: nil)

      expect(described_class.new(bot, {}).execute_request).to be_nil
    end
  end
end
