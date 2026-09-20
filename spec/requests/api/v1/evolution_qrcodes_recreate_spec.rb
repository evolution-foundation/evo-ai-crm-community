# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# Archiving an Evolution API WhatsApp channel logs its instance out, which
# can end up with Evolution API deleting the instance server-side (logout on
# an already-disconnected session fails there, and disconnect_channel_provider
# falls back to delete — see EvolutionConcern::InstanceNotFoundError). Without
# a recreate step, reactivating that channel and trying to reconnect dead-ends
# on a 404 forever.
RSpec.describe 'Evolution API QR code — recreate missing instance', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:channel) do
    # Channel::Whatsapp validates provider_config by pinging Evolution API's
    # root endpoint (see Whatsapp::Providers::EvolutionService#validate_provider_config?).
    stub_request(:get, 'https://evolution.example.com/')
      .to_return(status: 200, body: { status: 200 }.to_json)

    Channel::Whatsapp.create!(
      phone_number: '+5511999999999',
      provider: 'evolution',
      provider_config: {
        'api_url' => 'https://evolution.example.com',
        'admin_token' => 'admin-secret',
        'instance_name' => 'mateus'
      }
    )
  end
  let!(:inbox) { Inbox.create!(name: "Evolution QR Spec Inbox #{SecureRandom.hex(2)}", channel: channel) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('BACKEND_URL').and_return('https://crm.example.com')
  end

  after { Current.reset }

  it 'returns the QR code directly when the instance already exists' do
    stub_request(:get, 'https://evolution.example.com/instance/connect/mateus')
      .to_return(status: 200, body: { base64: 'data:image/png;base64,abc', pairingCode: nil }.to_json)

    get '/api/v1/evolution/qrcodes/mateus', as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'base64')).to eq('data:image/png;base64,abc')
    expect(a_request(:post, 'https://evolution.example.com/instance/create')).not_to have_been_made
  end

  it 'recreates the instance and retries when Evolution API reports it missing' do
    connect_stub = stub_request(:get, 'https://evolution.example.com/instance/connect/mateus')
                   .to_return(
                     { status: 404,
                       body: { status: 404, error: 'Not Found', response: { message: ['The "mateus" instance does not exist'] } }.to_json },
                     { status: 200, body: { base64: 'data:image/png;base64,fresh', pairingCode: nil }.to_json }
                   )
    create_stub = stub_request(:post, 'https://evolution.example.com/instance/create')
                  .with { |req| JSON.parse(req.body)['instanceName'] == 'mateus' && JSON.parse(req.body)['number'] == '5511999999999' }
                  .to_return(status: 201, body: { instance: { instanceName: 'mateus' } }.to_json)

    get '/api/v1/evolution/qrcodes/mateus', as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'base64')).to eq('data:image/png;base64,fresh')
    expect(create_stub).to have_been_requested
    expect(connect_stub).to have_been_requested.times(2)
  end

  it 'surfaces the original error when recreating also fails' do
    stub_request(:get, 'https://evolution.example.com/instance/connect/mateus')
      .to_return(status: 404, body: { error: 'Not Found' }.to_json)
    stub_request(:post, 'https://evolution.example.com/instance/create')
      .to_return(status: 500, body: 'boom')

    get '/api/v1/evolution/qrcodes/mateus', as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('Failed to create instance')
  end
end
