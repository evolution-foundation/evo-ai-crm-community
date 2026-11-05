# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# A WhatsApp channel's provider credentials reach only whoever may edit it, on
# every endpoint that serializes the inbox, and the settings screen saving the
# provider_config it received keeps them stored.
RSpec.describe 'WhatsApp provider credentials in inbox payloads', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:stored_config) do
    {
      'api_url' => 'https://evolution.test',
      'admin_token' => 'secret-evolution-admin',
      'instance_name' => 'loja-centro',
      'mark_as_read' => true
    }
  end

  let!(:user) { User.create!(name: 'Atendente', email: "atendente-#{SecureRandom.hex(4)}@example.com") }
  let!(:channel) do
    Channel::Whatsapp.new(phone_number: '+5511988887777', provider: 'evolution',
                          provider_config: stored_config, provider_connection: {})
                     .tap { |c| c.save!(validate: false) }
  end
  let!(:inbox) { Inbox.create!(channel: channel, name: 'WhatsApp Loja') }
  let!(:bot) { AgentBot.create!(name: 'Agente Loja', outgoing_url: 'https://example.test/bot') }
  let!(:contact) { Contact.create!(name: 'Cliente', phone_number: '+5511977776666') }

  around do |example|
    original_base_url = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    begin
      example.run
    ensure
      Rails.cache.clear
      Current.reset
      ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
    end
  end

  def stub_auth(granted:)
    stub_request(:post, "#{base_url}/api/v1/auth/validate")
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 2, key: 'agent', name: 'agent' } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        {
          status: 200,
          body: { success: true, data: { has_permission: granted.include?(JSON.parse(request.body)['permission_key']) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  before do
    InboxMember.create!(inbox: inbox, user: user)
    AgentBotInbox.create!(inbox: inbox, agent_bot: bot, status: :active)
    stub_request(:any, %r{\Ahttps://evolution\.test}).to_return(status: 200, body: '{}')
  end

  # The inbox as each endpoint renders it.
  def payloads
    {
      '/inboxes' => listed_inbox('/api/v1/inboxes'),
      '/inboxes/:id' => fetch_data("/api/v1/inboxes/#{inbox.id}"),
      '/agent_bots/:id/inboxes' =>
        fetch_data("/api/v1/agent_bots/#{bot.id}/inboxes").find { |row| row['inbox_id'] == inbox.id }&.dig('inbox'),
      '/contacts/:id/contactable_inboxes' => listed_inbox("/api/v1/contacts/#{contact.id}/contactable_inboxes")
    }
  end

  def fetch_data(path)
    get path, headers: headers
    response.parsed_body['data']
  end

  def listed_inbox(path)
    fetch_data(path).find { |row| row['id'] == inbox.id }
  end

  context 'when the user can read the channel but not edit it' do
    before { stub_auth(granted: %w[inboxes.read agent_bots.read contacts.read]) }

    it 'leaves the credentials out of every inbox payload' do
      payloads.each do |endpoint, payload|
        expect(payload).to be_present, "#{endpoint} did not list the inbox"
        expect(payload['provider_config']).to eq(stored_config.except('admin_token')), endpoint.to_s
        expect(payload.to_json).not_to include('secret-'), endpoint.to_s
      end
    end
  end

  context 'when the user can edit the channel' do
    before { stub_auth(granted: %w[inboxes.read inboxes.update agent_bots.read contacts.read]) }

    it 'hands the whole provider_config on every inbox payload' do
      payloads.each do |endpoint, payload|
        expect(payload['provider_config']).to eq(stored_config), endpoint.to_s
      end
    end

    it 'keeps the stored credentials when the settings screen saves what it received' do
      get "/api/v1/inboxes/#{inbox.id}", headers: headers
      received = response.parsed_body.dig('data', 'provider_config')

      patch "/api/v1/inboxes/#{inbox.id}",
            params: { channel: { provider_config: received.merge('mark_as_read' => false) } },
            headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(channel.reload.provider_config).to eq(stored_config.merge('mark_as_read' => false))
    end
  end
end
