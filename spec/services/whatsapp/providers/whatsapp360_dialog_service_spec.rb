# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Whatsapp::Providers::Whatsapp360DialogService do
  let(:whatsapp_channel) do
    instance_double(
      Channel::Whatsapp,
      id: 'e1f0a0a2-0000-4000-8000-000000000001',
      phone_number: '+5511900000001',
      provider_config: { 'api_key' => 'd360-key' }
    )
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }
  let(:webhook_config_url) { 'https://waba.360dialog.io/v1/configs/webhook' }

  describe '#probe_credential' do
    it 'reads the webhook config with the channel key and reports :ok' do
      stub_request(:get, webhook_config_url)
        .with(headers: { 'D360-API-KEY' => 'd360-key' })
        .to_return(status: 200, body: '{"url":"https://crm.test/webhooks/whatsapp/+5511900000001"}')

      expect(service.probe_credential).to eq(:ok)
    end

    it 'reports :rejected when the provider refuses the key' do
      stub_request(:get, webhook_config_url).to_return(status: 401, body: '{"meta":{"success":false}}')

      expect(service.probe_credential).to eq(:rejected)
    end

    it 'reports :rejected when the provider forbids the key' do
      stub_request(:get, webhook_config_url).to_return(status: 403, body: '{"meta":{"success":false}}')

      expect(service.probe_credential).to eq(:rejected)
    end

    # A provider that is down told us nothing about the credential; answering
    # :rejected here would revoke a healthy channel over a 360dialog outage.
    it 'reports :inconclusive when the provider is unavailable' do
      stub_request(:get, webhook_config_url).to_return(status: 503, body: 'upstream down')

      expect(service.probe_credential).to eq(:inconclusive)
    end

    it 'reports :inconclusive when the provider answers with a rate limit' do
      stub_request(:get, webhook_config_url).to_return(status: 429, body: '{"meta":{"success":false}}')

      expect(service.probe_credential).to eq(:inconclusive)
    end

    # The whole reason this method exists apart from validate_provider_config?:
    # the scheduler repeats it every few hours, so it may not change anything
    # on the provider. One request, and it is a read.
    it 'writes nothing on the provider' do
      stub_request(:any, /360dialog\.io/).to_return(status: 200, body: '{}')

      service.probe_credential

      expect(a_request(:get, webhook_config_url)).to have_been_made.once
      expect(a_request(:any, /360dialog\.io/)).to have_been_made.once
    end
  end

  # Save-time validation keeps registering the webhook: that write is the point
  # of the call, and it is what the read-only probe had to be split away from.
  describe '#validate_provider_config?' do
    it 'still registers the webhook' do
      stub = stub_request(:post, webhook_config_url).to_return(status: 200, body: '{}')

      expect(service.validate_provider_config?).to be(true)
      expect(stub).to have_been_requested
    end
  end
end
