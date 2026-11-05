# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# The code paths that look a WhatsApp channel up and log its provider_config
# log the key names only, never a credential value.
RSpec.describe 'WhatsApp provider credentials in logs' do
  before do
    stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
  end

  # Everything logged while the block runs, setup left out.
  def logs_of
    logged = []
    %i[debug info warn error].each do |level|
      allow(Rails.logger).to receive(level).and_wrap_original do |original, *args, &block|
        logged << (args.first || block&.call).to_s
        original.call(*args, &block)
      end
    end
    yield
    logged.join("\n")
  end

  def whatsapp_inbox(provider, config)
    channel = Channel::Whatsapp.new(phone_number: "+55119#{rand(10**8).to_s.rjust(8, '0')}", provider: provider,
                                    provider_config: config, provider_connection: {})
                               .tap { |c| c.save!(validate: false) }
    Inbox.create!(channel: channel, name: "WA #{provider}")
  end

  def controller_with(klass, params)
    klass.new.tap { |controller| controller.params = ActionController::Parameters.new(params) }
  end

  let(:zapi_config) do
    { 'instance_id' => 'zapi-instance-3', 'token' => 'secret-zapi-token', 'client_token' => 'secret-zapi-client' }
  end
  let(:evolution_go_config) do
    { 'api_url' => 'https://evolution-go.test', 'admin_token' => 'secret-go-admin',
      'instance_token' => 'secret-go-instance', 'instance_uuid' => 'go-uuid-1', 'instance_name' => 'loja-go' }
  end

  it 'leaves the Z-API credentials out of the validation logs' do
    inbox = whatsapp_inbox('zapi', zapi_config)

    logs = logs_of do
      expect(Whatsapp::Providers::ZapiService.new(whatsapp_channel: inbox.channel).validate_provider_config?).to be(true)
    end

    expect(logs).to include('zapi-instance-3').and(include('token: present'))
    expect(logs).not_to include('secret-')
  end

  it 'leaves the Z-API credentials out of the QR code lookup log' do
    whatsapp_inbox('zapi', zapi_config)

    logs = logs_of { controller_with(Api::V1::Zapi::QrcodesController, id: 'zapi-instance-3').send(:set_instance_params) }

    expect(logs).to include('config keys')
    expect(logs).not_to include('secret-')
  end

  it 'leaves the Evolution Go credentials out of the QR code lookup log' do
    whatsapp_inbox('evolution_go', evolution_go_config)

    logs = logs_of { controller_with(Api::V1::EvolutionGo::QrcodesController, id: 'loja-go').send(:set_instance_params) }

    expect(logs).to include('config keys')
    expect(logs).not_to include('secret-')
  end

  it 'leaves the Evolution Go credentials out of the authorization lookup log' do
    whatsapp_inbox('evolution_go', evolution_go_config)
    allow(GlobalConfigService).to receive(:load).and_return('')

    logs = logs_of { controller_with(Api::V1::EvolutionGo::AuthorizationsController, instance_uuid: 'go-uuid-1').send(:set_instance_params) }

    expect(logs).to include('config keys')
    expect(logs).not_to include('secret-')
  end

  it 'leaves the credentials out of the sync listener log' do
    inbox = whatsapp_inbox('evolution_go', evolution_go_config)

    logs = logs_of { WhatsappSyncListener.instance.send(:sync_enabled?, inbox) }

    expect(logs).to include('Provider config keys')
    expect(logs).not_to include('secret-')
  end
end
