require 'rails_helper'

RSpec.describe Whatsapp::Providers::WahaService do
  let(:provider_config) do
    { 'base_url' => 'https://waha.example.com', 'api_key' => 'secret-key', 'session_name' => 'default' }
  end
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, provider_config: provider_config) }
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#validate_provider_config?' do
    it 'returns false when base_url is blank' do
      allow(whatsapp_channel).to receive(:provider_config).and_return(provider_config.merge('base_url' => ''))
      expect(service.validate_provider_config?).to eq(false)
    end

    it 'returns false when api_key is blank' do
      allow(whatsapp_channel).to receive(:provider_config).and_return(provider_config.merge('api_key' => ''))
      expect(service.validate_provider_config?).to eq(false)
    end

    it 'returns false when session_name is blank' do
      allow(whatsapp_channel).to receive(:provider_config).and_return(provider_config.merge('session_name' => ''))
      expect(service.validate_provider_config?).to eq(false)
    end

    it 'returns true and hits GET /api/sessions/:session when config is present' do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: '{}', parsed_response: {})
      expect(HTTParty).to receive(:get).with(
        'https://waha.example.com/api/sessions/default',
        hash_including(headers: { 'X-Api-Key' => 'secret-key', 'Content-Type' => 'application/json' })
      ).and_return(response)

      expect(service.validate_provider_config?).to eq(true)
    end

    it 'returns false when the session lookup fails' do
      response = instance_double(HTTParty::Response, success?: false, code: 404, body: 'not found', parsed_response: {})
      allow(HTTParty).to receive(:get).and_return(response)

      expect(service.validate_provider_config?).to eq(false)
    end
  end

  describe '#send_message' do
    let(:message) { instance_double(Message, attachments: [], content_type: 'text', content: 'Hello there') }

    it 'posts to /api/sendText with the session and chatId' do
      response = instance_double(HTTParty::Response, success?: true, code: 201, body: '{}', parsed_response: { 'id' => 'true_5511999999999@c.us_ABCDEF' })
      expect(HTTParty).to receive(:post).with(
        'https://waha.example.com/api/sendText',
        hash_including(
          headers: { 'X-Api-Key' => 'secret-key', 'Content-Type' => 'application/json' },
          body: { session: 'default', chatId: '5511999999999@c.us', text: 'Hello there' }.to_json
        )
      ).and_return(response)

      result = service.send_message('+5511999999999', message)
      expect(result).to eq('true_5511999999999@c.us_ABCDEF')
    end

    it 'marks the message unsupported when there is no content or attachments' do
      empty_message = instance_double(Message, attachments: [], content_type: 'text', content: nil)
      expect(empty_message).to receive(:update!).with(is_unsupported: true)

      service.send_message('+5511999999999', empty_message)
    end
  end

  describe '#check_number_exists?' do
    it 'returns true when WAHA reports the number exists' do
      response = instance_double(
        HTTParty::Response, success?: true,
        parsed_response: [{ 'numberExists' => true, 'chatId' => '5511999999999@c.us' }]
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?('+5511999999999')).to eq(true)
    end

    it 'returns nil when the HTTP call fails' do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

      expect(service.check_number_exists?('+5511999999999')).to be_nil
    end
  end

  describe '#disconnect_channel_provider' do
    it 'logs out and stops the session' do
      logout_response = instance_double(HTTParty::Response, code: 200, body: '{}')
      stop_response = instance_double(HTTParty::Response, code: 200, body: '{}')

      expect(HTTParty).to receive(:post).with(
        'https://waha.example.com/api/sessions/default/logout',
        hash_including(headers: { 'X-Api-Key' => 'secret-key', 'Content-Type' => 'application/json' })
      ).and_return(logout_response)
      expect(HTTParty).to receive(:post).with(
        'https://waha.example.com/api/sessions/default/stop',
        hash_including(headers: { 'X-Api-Key' => 'secret-key', 'Content-Type' => 'application/json' })
      ).and_return(stop_response)

      service.disconnect_channel_provider
    end
  end
end
