# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# This file did not exist in this fork before CRM-359: upstream's version also
# covers #probe_credential (CRM-489), which this fork's
# Whatsapp::Providers::Whatsapp360DialogService does not implement, so only the
# CRM-359 coverage (and the pre-existing #validate_provider_config? behaviour
# it sits next to) is brought over here.
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

  # CRM-359: same component shape as the Cloud provider — the button rides after the body.
  describe '#send_template' do
    let(:messages_url) { 'https://waba.360dialog.io/v1/messages' }
    let(:template_info) do
      { name: 'convite', namespace: 'ns', lang_code: 'pt_BR',
        parameters: [{ type: 'text', text: 'João' }],
        button_components: [{ type: 'button', sub_type: 'url', index: '0',
                              parameters: [{ type: 'text', text: 'abc123' }] }] }
    end

    it 'appends the button components after the body component' do
      stub = stub_request(:post, messages_url).with do |req|
        JSON.parse(req.body)['template']['components'] == [
          { 'type' => 'body', 'parameters' => [{ 'type' => 'text', 'text' => 'João' }] },
          { 'type' => 'button', 'sub_type' => 'url', 'index' => '0',
            'parameters' => [{ 'type' => 'text', 'text' => 'abc123' }] }
        ]
      end.to_return(status: 200, body: '{"messages":[{"id":"wamid.1"}]}', headers: { 'Content-Type' => 'application/json' })

      service.send_template('5511999999999', template_info)

      expect(stub).to have_been_requested
    end

    it 'sends only the body component when there is no button component' do
      stub = stub_request(:post, messages_url).with do |req|
        JSON.parse(req.body)['template']['components'].map { |c| c['type'] } == ['body']
      end.to_return(status: 200, body: '{"messages":[{"id":"wamid.1"}]}', headers: { 'Content-Type' => 'application/json' })

      service.send_template('5511999999999', template_info.except(:button_components))

      expect(stub).to have_been_requested
    end
  end

  describe '#validate_provider_config?' do
    it 'still registers the webhook' do
      stub = stub_request(:post, webhook_config_url).to_return(status: 200, body: '{}')

      expect(service.validate_provider_config?).to be(true)
      expect(stub).to have_been_requested
    end
  end
end
