# frozen_string_literal: true

require 'rails_helper'

# The send-response contract consumed by SendOnWhatsappService: a delivered
# send without an ID must not read as a failure.
RSpec.describe Whatsapp::Providers::EvolutionGoService do
  let(:whatsapp_channel) do
    instance_double(Channel::Whatsapp, provider_config: { 'api_key' => 'token', 'instance_name' => 'inst' })
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#process_evolution_go_response' do
    it 'returns the message id when the API provides one' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'data' => { 'Info' => { 'ID' => 'GO123' } }, 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to eq('GO123')
    end

    it 'returns true (success without id) when HTTP 200 carries no ID' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to be(true)
    end

    it 'raises on HTTP error (handled by SendReplyJob rescue)' do
      response = instance_double(
        HTTParty::Response,
        success?: false, code: 500,
        parsed_response: {},
        body: 'boom'
      )

      expect { service.send(:process_evolution_go_response, response) }
        .to raise_error(/HTTP 500/)
    end
  end

  describe '#send_message — unsupported content (CRM-448)' do
    it 'flags the message is_unsupported and returns nil (the caller turns it into failed)' do
      message = instance_double(Message, attachments: [], content_type: 'text', content: nil)
      expect(message).to receive(:update!).with(is_unsupported: true)

      expect(service.send_message('5511999999999', message)).to be_nil
    end
  end

  describe '#toggle_typing_status' do
    let(:whatsapp_channel) do
      instance_double(Channel::Whatsapp, provider_config: {
                         'api_url' => 'https://evo-go.example.com',
                         'instance_token' => 'inst-token'
                       })
    end

    it 'POSTs composing state to /message/presence for typing_on' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}')
      expect(HTTParty).to receive(:post).with(
        'https://evo-go.example.com/message/presence',
        hash_including(
          headers: { 'apikey' => 'inst-token', 'Content-Type' => 'application/json' },
          body: { number: '+5511999999999', state: 'composing', isAudio: false }.to_json
        )
      ).and_return(response)

      expect(service.toggle_typing_status('+5511999999999', 'conversation.typing_on')).to eq(true)
    end

    it 'sets isAudio true and state composing for conversation.recording' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}')
      expect(HTTParty).to receive(:post).with(
        anything,
        hash_including(body: { number: '+5511999999999', state: 'composing', isAudio: true }.to_json)
      ).and_return(response)

      service.toggle_typing_status('+5511999999999', 'conversation.recording')
    end

    it 'maps conversation.typing_off to state paused' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}')
      expect(HTTParty).to receive(:post).with(
        anything,
        hash_including(body: { number: '+5511999999999', state: 'paused', isAudio: false }.to_json)
      ).and_return(response)

      service.toggle_typing_status('+5511999999999', 'conversation.typing_off')
    end

    it 'returns false and swallows the error when the HTTP call raises' do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

      expect(service.toggle_typing_status('+5511999999999', 'conversation.typing_on')).to eq(false)
    end
  end
end
