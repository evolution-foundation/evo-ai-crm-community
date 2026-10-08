# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# CRM-41: the agent's Channels tab lists its bindings, unlinks them by
# deactivating (the row and its configuration survive), and the inbox payload
# says which agent answers a channel so linking it elsewhere can warn first.
RSpec.describe 'Api::V1 agent bot inboxes', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Bot Binder', email: "bot-binder-#{SecureRandom.hex(4)}@example.com") }
  let!(:bot) { AgentBot.create!(name: 'Agente Vendas', outgoing_url: 'https://example.test/bot') }
  let!(:other_bot) { AgentBot.create!(name: 'Agente Suporte', outgoing_url: 'https://example.test/other') }
  let!(:inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Canal Vendas') }
  let!(:paused_inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Canal Pausado') }
  let!(:other_inbox) { Inbox.create!(channel: Channel::Api.create!, name: 'Canal Suporte') }
  let!(:label) { Label.create!(title: "vip-#{SecureRandom.hex(3)}", color: '#abcdef') }

  let!(:bot_binding) do
    AgentBotInbox.create!(inbox: inbox, agent_bot: bot, status: :active,
                          allowed_conversation_statuses: %w[pending open], allowed_label_ids: [label.id])
  end
  let!(:paused_binding) { AgentBotInbox.create!(inbox: paused_inbox, agent_bot: bot, status: :inactive) }
  let!(:other_binding) { AgentBotInbox.create!(inbox: other_inbox, agent_bot: other_bot, status: :active) }

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

  # `granted: nil` grants every permission key.
  def stub_auth(role_key: 'administrator', granted: nil)
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: role_key, name: role_key } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: granted.nil? || granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  before do
    stub_auth
    Current.user = user
  end

  describe 'GET /api/v1/agent_bots/:id/inboxes' do
    it 'lists the active and inactive bindings of the bot, and only its own' do
      get "/api/v1/agent_bots/#{bot.id}/inboxes", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body['data']
      expect(data.map { |row| row['inbox_id'] }).to contain_exactly(inbox.id, paused_inbox.id)

      active = data.find { |row| row['inbox_id'] == inbox.id }
      expect(active['status']).to eq('active')
      expect(active.dig('inbox', 'name')).to eq('Canal Vendas')
      expect(active.dig('configuration', 'allowed_conversation_statuses')).to eq(%w[pending open])
      expect(active.dig('configuration', 'allowed_label_ids')).to eq([label.id])

      expect(data.find { |row| row['inbox_id'] == paused_inbox.id }['status']).to eq('inactive')
    end

    it 'leaves out the inboxes the caller cannot see' do
      InboxMember.create!(inbox: inbox, user: user)
      stub_auth(role_key: 'agent_restricted', granted: %w[inboxes.read])

      get "/api/v1/agent_bots/#{bot.id}/inboxes", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data'].map { |row| row['inbox_id'] }).to contain_exactly(inbox.id)
    end

    it 'answers 404 for an unknown bot' do
      get "/api/v1/agent_bots/#{SecureRandom.uuid}/inboxes", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 403 when the caller lacks inboxes.read' do
      stub_auth(role_key: 'agent_restricted', granted: [])

      get "/api/v1/agent_bots/#{bot.id}/inboxes", headers: headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/v1/inboxes/:id/agent_bot_inbox' do
    it 'deactivates the binding keeping the row and its configuration' do
      expect do
        patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox", params: { status: 'inactive' }, headers: headers, as: :json
      end.not_to change(AgentBotInbox, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'status')).to eq('inactive')

      bot_binding.reload
      expect(bot_binding).to be_inactive
      expect(bot_binding.agent_bot).to eq(bot)
      expect(bot_binding.allowed_conversation_statuses).to eq(%w[pending open])
      expect(bot_binding.allowed_label_ids).to eq([label.id])
      # The bot stops answering: every runtime gate reads active_bot?.
      expect(inbox.reload.active_bot?).to be(false)
    end

    it 'reactivates with the same configuration' do
      bot_binding.update!(status: :inactive)

      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox", params: { status: 'active' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      bot_binding.reload
      expect(bot_binding).to be_active
      expect(bot_binding.allowed_conversation_statuses).to eq(%w[pending open])
      expect(bot_binding.allowed_label_ids).to eq([label.id])
    end

    it 'saves the configuration without reactivating an inactive binding' do
      patch "/api/v1/inboxes/#{paused_inbox.id}/agent_bot_inbox",
            params: { agent_bot_config: { allowed_conversation_statuses: %w[open], ignored_label_ids: [label.id] } },
            headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      paused_binding.reload
      expect(paused_binding).to be_inactive
      expect(paused_binding.allowed_conversation_statuses).to eq(%w[open])
      expect(paused_binding.ignored_label_ids).to eq([label.id])
    end

    it 'leaves the keys it was not sent untouched' do
      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox",
            params: { agent_bot_config: { ignored_label_ids: [] } }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(bot_binding.reload.allowed_conversation_statuses).to eq(%w[pending open])
      expect(bot_binding.allowed_label_ids).to eq([label.id])
    end

    it 'falls back to pending when the status list is emptied' do
      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox",
            params: { agent_bot_config: { allowed_conversation_statuses: [] } }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(bot_binding.reload.allowed_conversation_statuses).to eq(%w[pending])
    end

    it 'rejects an unknown status without touching the binding' do
      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox", params: { status: 'paused' }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(bot_binding.reload).to be_active
    end

    it 'refuses with 409 when the channel moved to another agent' do
      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox",
            params: { status: 'inactive', agent_bot_id: other_bot.id }, headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(bot_binding.reload).to be_active
    end

    it 'still unlinks when a label it referenced was deleted' do
      gone = SecureRandom.uuid
      bot_binding.update_columns(allowed_label_ids: [label.id, gone], ignored_label_ids: [gone])

      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox",
            params: { status: 'inactive', agent_bot_id: bot.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      bot_binding.reload
      expect(bot_binding).to be_inactive
      expect(bot_binding.allowed_label_ids).to eq([label.id])
      expect(bot_binding.ignored_label_ids).to eq([])
    end

    it 'answers 404 when the inbox has no binding' do
      unbound = Inbox.create!(channel: Channel::Api.create!, name: 'Canal Livre')

      patch "/api/v1/inboxes/#{unbound.id}/agent_bot_inbox", params: { status: 'inactive' }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(AgentBotInbox.where(inbox_id: unbound.id)).to be_empty
    end

    # A member of the inbox passes the inbox policy, so only the inboxes.update
    # gate stands between a read-only user and deactivating the agent.
    it 'answers 403 when the caller lacks inboxes.update' do
      InboxMember.create!(inbox: inbox, user: user)
      stub_auth(role_key: 'agent_restricted', granted: %w[inboxes.read])

      patch "/api/v1/inboxes/#{inbox.id}/agent_bot_inbox", params: { status: 'inactive' }, headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(bot_binding.reload).to be_active
    end
  end

  describe 'POST /api/v1/inboxes/:id/set_agent_bot (transfer)' do
    it "starts the new agent on defaults instead of the previous agent's configuration" do
      other_binding.update!(moderation_enabled: true, explicit_words_filter: %w[palavra],
                            facebook_interaction_type: 'comments_only', allowed_label_ids: [label.id])

      post "/api/v1/inboxes/#{other_inbox.id}/set_agent_bot", params: { agent_bot: bot.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      other_binding.reload
      expect(other_binding.agent_bot).to eq(bot)
      expect(other_binding.moderation_enabled).to be(false)
      expect(other_binding.explicit_words_filter).to eq([])
      expect(other_binding.facebook_interaction_type).to eq('both')
      expect(other_binding.allowed_label_ids).to eq([])
      expect(other_binding.allowed_conversation_statuses).to eq(%w[pending])
    end

    it 'keeps the configuration when the same agent is set again' do
      bot_binding.update!(moderation_enabled: true)

      post "/api/v1/inboxes/#{inbox.id}/set_agent_bot", params: { agent_bot: bot.id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(bot_binding.reload.moderation_enabled).to be(true)
    end
  end

  describe 'which agent answers a channel' do
    it 'is part of the inbox list, for bound and unbound inboxes' do
      unbound = Inbox.create!(channel: Channel::Api.create!, name: 'Canal Livre')

      get '/api/v1/inboxes', headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body['data'].index_by { |row| row['id'] }
      expect(rows[other_inbox.id]['agent_bot']).to include('id' => other_bot.id, 'name' => 'Agente Suporte', 'status' => 'active')
      expect(rows[paused_inbox.id]['agent_bot']).to include('id' => bot.id, 'status' => 'inactive')
      expect(rows[unbound.id]['agent_bot']).to be_nil
    end

    it 'is part of the inbox detail' do
      get "/api/v1/inboxes/#{other_inbox.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'agent_bot', 'id')).to eq(other_bot.id)
    end

    it 'reports the binding status on GET /inboxes/:id/agent_bot' do
      get "/api/v1/inboxes/#{paused_inbox.id}/agent_bot", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'configuration', 'status')).to eq('inactive')
    end
  end
end
