# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-2072 — the AgentsController proxies AI-agent CRUD to evo-core and is gated
# by `ai_agents.*` (repointed from the dead twin `agents.*`). This spec proves
# the repoint end-to-end through the bearer-auth path: we WebMock-stub evo-auth's
# /validate (carries the role key) and /check_permission (answers per key), and
# stub EvoAiCoreService so the proxy never touches the real core. A role holding
# the new `ai_agents.*` gate passes; one holding only the stale `agents.*` (or
# nothing) is forbidden.
RSpec.describe 'Api::V1::Agents (ai_agents gate)', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  let!(:user) { User.create!(name: 'Agent Screen User', email: "agents-#{SecureRandom.hex(4)}@example.com") }

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  def json_response
    JSON.parse(response.body)
  end

  # Stubs /validate to return the given role key, and /check_permission for the
  # given user to answer `true` only for the permission keys in `granted`.
  def stub_auth(role_key:, granted: [])
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
          body: { success: true, data: { has_permission: granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  before do
    # Proxy target: never hit the real evo-core. Any of these responses is fine —
    # the gate runs (and can deny) before the proxy is reached.
    allow(EvoAiCoreService).to receive(:list_agents).and_return({ 'data' => [] })
    allow(EvoAiCoreService).to receive(:create_agent).and_return({ 'id' => 'agent-1' })
    allow(EvoAiCoreService).to receive(:update_agent).and_return({ 'id' => 'agent-1' })
    allow(EvoAiCoreService).to receive(:delete_agent).and_return(nil)
  end

  context 'with a role that holds the ai_agents.* gate' do
    before do
      stub_auth(role_key: 'custom_ai_manager',
                granted: %w[ai_agents.read ai_agents.create ai_agents.update ai_agents.delete])
    end

    it 'allows index (ai_agents.read)' do
      get '/api/v1/agents', headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(EvoAiCoreService).to have_received(:list_agents)
    end

    it 'allows create (ai_agents.create)' do
      post '/api/v1/agents', params: { name: 'Bot' }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(EvoAiCoreService).to have_received(:create_agent)
    end

    it 'allows update (ai_agents.update)' do
      patch '/api/v1/agents/agent-1', params: { name: 'Bot 2' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(EvoAiCoreService).to have_received(:update_agent)
    end

    it 'allows destroy (ai_agents.delete)' do
      delete '/api/v1/agents/agent-1', headers: headers, as: :json
      expect(response).to have_http_status(:no_content)
      expect(EvoAiCoreService).to have_received(:delete_agent)
    end
  end

  context 'with a role that holds only the stale agents.* gate (proves the repoint)' do
    before { stub_auth(role_key: 'legacy_role', granted: %w[agents.read agents.create agents.update agents.delete]) }

    it 'forbids index' do
      get '/api/v1/agents', headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(EvoAiCoreService).not_to have_received(:list_agents)
    end

    it 'forbids create' do
      post '/api/v1/agents', params: { name: 'Bot' }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(EvoAiCoreService).not_to have_received(:create_agent)
    end
  end

  context 'with a role that holds no relevant grant' do
    before { stub_auth(role_key: 'no_grants', granted: []) }

    it 'forbids index' do
      get '/api/v1/agents', headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  # CRM-565 — the reported bug. These examples let the real EvoAiCoreService run
  # (the outer `before` stub is undone with and_call_original) and cut the wire at
  # the HTTP boundary instead, so the whole proxy path is exercised: the HTTParty
  # call, handle_response, and the controller's translation. Each one asserts the
  # absence of 500 explicitly — that is the symptom the customer reported.
  context 'when evo-core fails (CRM-565)' do
    let(:core_agents_url) { %r{\A#{Regexp.escape(EvoAiCoreService.base_uri)}/api/v1/agents} }

    before do
      stub_auth(role_key: 'custom_ai_manager',
                granted: %w[ai_agents.read ai_agents.create ai_agents.update ai_agents.delete])

      allow(EvoAiCoreService).to receive(:list_agents).and_call_original
      allow(EvoAiCoreService).to receive(:create_agent).and_call_original
      allow(EvoAiCoreService).to receive(:update_agent).and_call_original
      allow(EvoAiCoreService).to receive(:delete_agent).and_call_original
    end

    def core_json(status, body)
      { status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
    end

    context 'when the core is unreachable' do
      it 'answers 503 on index, never 500' do
        stub_request(:get, core_agents_url).to_raise(Errno::ECONNREFUSED)

        get '/api/v1/agents', headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:service_unavailable)
        expect(json_response['error']['code']).to eq('SERVICE_UNAVAILABLE')
      end

      it 'answers 503 on create, never 500' do
        stub_request(:post, core_agents_url).to_raise(Errno::ECONNREFUSED)

        post '/api/v1/agents', params: { name: 'Bot' }, headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:service_unavailable)
      end

      it 'answers 503 on update, never 500' do
        stub_request(:put, core_agents_url).to_timeout

        patch '/api/v1/agents/agent-1', params: { name: 'Bot 2' }, headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:service_unavailable)
      end

      it 'answers 503 on destroy, never 500' do
        stub_request(:delete, core_agents_url).to_raise(SocketError)

        delete '/api/v1/agents/agent-1', headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:service_unavailable)
      end

      it 'keeps the failure detail in the log and out of the body' do
        stub_request(:get, core_agents_url).to_raise(Errno::ECONNREFUSED)
        allow(Rails.logger).to receive(:error)

        get '/api/v1/agents', headers: headers, as: :json

        expect(Rails.logger).to have_received(:error).with(/did not reach evo-core/)
        expect(response.body).not_to include('ECONNREFUSED')
      end
    end

    context 'when the core answers 4xx' do
      it 'relays 422 instead of 500' do
        stub_request(:post, core_agents_url).to_return(core_json(422, { error: 'model is required' }))

        post '/api/v1/agents', params: { name: 'Bot' }, headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response['error']['details']['upstream_status']).to eq(422)
      end

      it 'relays 404 instead of 500' do
        stub_request(:delete, core_agents_url).to_return(core_json(404, { error: 'agent not found' }))

        delete '/api/v1/agents/agent-1', headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:not_found)
      end

      it 'does not echo the core wording back to the client' do
        stub_request(:get, core_agents_url)
          .to_return(core_json(400, { error: 'pq: relation "evo_core_agents" does not exist' }))

        get '/api/v1/agents', headers: headers, as: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.body).not_to include('evo_core_agents')
      end
    end

    context 'when the core answers 5xx' do
      it 'answers 502, so the CRM is not blamed for the core breaking' do
        stub_request(:get, core_agents_url).to_return(core_json(500, { error: 'boom' }))

        get '/api/v1/agents', headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:bad_gateway)
        expect(json_response['error']['details']['upstream_status']).to eq(500)
      end
    end

    context 'when the core answers 2xx' do
      it 'still returns 200 with the data payload unwrapped' do
        stub_request(:get, core_agents_url)
          .to_return(core_json(200, { data: [{ id: 'agent-1', name: 'Bot' }] }))

        get '/api/v1/agents', headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response.first['id']).to eq('agent-1')
      end

      it 'returns 200 for a bare JSON array (the payload shape that used to raise)' do
        # `parsed.dig('data')` on an Array raises TypeError, which the base
        # controller turned into a 500 for a perfectly good 200 upstream.
        stub_request(:get, core_agents_url).to_return(core_json(200, [{ id: 'agent-1' }]))

        get '/api/v1/agents', headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:ok)
        expect(json_response.first['id']).to eq('agent-1')
      end

      it 'returns 200 when the body is not JSON at all' do
        stub_request(:get, core_agents_url)
          .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/plain' })

        get '/api/v1/agents', headers: headers, as: :json

        expect(response).not_to have_http_status(:internal_server_error)
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
