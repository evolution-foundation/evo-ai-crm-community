# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::EvolutionGoService do
  let(:provider_config) do
    {
      'api_url' => 'https://evo-go.example.com',
      'instance_token' => 'instance-token'
    }
  end
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, provider_config: provider_config) }
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }
  let(:phone_number) { '+5511999999999' }

  describe '#check_number_exists?' do
    it 'POSTs to /user/check and returns true when the number is on WhatsApp' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'message' => 'success', 'data' => { 'Users' => [{ 'IsInWhatsapp' => true, 'JID' => '5511999999999@s.whatsapp.net' }] } }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?(phone_number)).to eq(true)
      expect(HTTParty).to have_received(:post) do |request_url, opts|
        expect(request_url).to eq('https://evo-go.example.com/user/check')
        expect(JSON.parse(opts[:body])).to eq('number' => ['5511999999999'])
        expect(opts[:headers]['apikey']).to eq('instance-token')
      end
    end

    it 'returns false when Evolution Go reports the number is not on WhatsApp' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'message' => 'success', 'data' => { 'Users' => [{ 'IsInWhatsapp' => false }] } }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?(phone_number)).to eq(false)
    end

    it 'returns nil when the upstream call fails, without raising' do
      response = instance_double(HTTParty::Response, success?: false, code: 500)
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.check_number_exists?(phone_number)).to be_nil
    end

    it 'returns nil and rescues network errors' do
      allow(HTTParty).to receive(:post).and_raise(SocketError, 'connection refused')

      expect { service.check_number_exists?(phone_number) }.not_to raise_error
      expect(service.check_number_exists?(phone_number)).to be_nil
    end

    it 'returns nil for blank input without hitting the network' do
      expect(HTTParty).not_to receive(:post)
      expect(service.check_number_exists?('')).to be_nil
      expect(service.check_number_exists?(nil)).to be_nil
    end
  end
end
