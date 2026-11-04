# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# The campaigns proxy is one routed action behind a `*path` glob, like the
# journeys one: the permission it demands and the traversal guard both depend on
# the real router populating params[:path], so the coverage lives here.
RSpec.describe 'Campaigns proxy RBAC', type: :request do
  let(:api_url) { 'http://evo-flow.test/api/v1' }
  let(:user) { User.create!(name: 'Campaign Probe', email: "campaign-#{SecureRandom.hex(4)}@example.com") }
  let(:json) { { 'Content-Type' => 'application/json' } }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch)
      .with('EVO_FLOW_API_URL', EvoFlow::Client::DEFAULT_API_URL).and_return(api_url)
    allow(ENV).to receive(:fetch)
      .with('AUTH_APIKEY_INTEGRATION_LOCAL', nil).and_return('integration-key')
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'the glob actually routes and forwards' do
    it 'GET /api/v1/campaigns reaches evo-flow /campaigns with the query' do
      grant_permissions('campaigns.read')
      stub = stub_request(:get, "#{api_url}/campaigns")
             .with(query: { 'page' => '2', 'status' => %w[draft running] },
                   headers: { 'X-Integration-API-Key' => 'integration-key' })
             .to_return(status: 200, body: { data: [] }.to_json, headers: json)

      get '/api/v1/campaigns', params: { page: 2, status: %w[draft running] }

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end

    it 'POST /api/v1/campaigns creates through evo-flow and relays 201' do
      grant_permissions('campaigns.create')
      stub = stub_request(:post, "#{api_url}/campaigns")
             .with(body: { title: 'Black Friday', name: 'black-friday' }.to_json)
             .to_return(status: 201, body: { data: { id: 'c1' } }.to_json, headers: json)

      post '/api/v1/campaigns', params: { title: 'Black Friday', name: 'black-friday' }, as: :json

      expect(response).to have_http_status(:created)
      expect(stub).to have_been_requested
    end

    it 'POST /api/v1/campaigns/:id/schedule reaches the nested subpath' do
      grant_permissions('campaigns.schedule')
      stub = stub_request(:post, "#{api_url}/campaigns/c1/schedule")
             .with(body: { scheduleTo: '2026-11-01T10:00:00Z' }.to_json)
             .to_return(status: 200, body: { data: { id: 'c1' } }.to_json, headers: json)

      post '/api/v1/campaigns/c1/schedule', params: { scheduleTo: '2026-11-01T10:00:00Z' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end

    it 'relays evo-flow 204 on delete' do
      grant_permissions('campaigns.delete')
      stub_request(:delete, "#{api_url}/campaigns/c1").to_return(status: 204, body: '')

      delete '/api/v1/campaigns/c1'

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
    end
  end

  # A browser that picks its tenant by cookie sends no X-Evo-Tenant-Id; the
  # tenant the request resolved has to reach evo-flow anyway, or a multi-tenant
  # evo-flow answers 401 TENANT_REQUIRED.
  describe 'tenant passthrough' do
    let(:tenant) { '2c013165-3992-4e6f-ba0d-4b6cb768a5d6' }

    it 'forwards the tenant the request resolved when the caller sent no header' do
      grant_permissions('campaigns.read')
      allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return(tenant)
      stub = stub_request(:get, "#{api_url}/campaigns")
             .with(headers: { 'X-Evo-Tenant-Id' => tenant })
             .to_return(status: 200, body: { data: [] }.to_json, headers: json)

      get '/api/v1/campaigns'

      expect(stub).to have_been_requested
    end

    it 'sends no tenant when the deployment resolves none (single-tenant)' do
      grant_permissions('campaigns.read')
      stub_request(:get, "#{api_url}/campaigns").to_return(status: 200, body: { data: [] }.to_json, headers: json)

      get '/api/v1/campaigns'

      expect(a_request(:get, "#{api_url}/campaigns").with { |req| !req.headers.key?('X-Evo-Tenant-Id') })
        .to have_been_made
    end
  end

  describe 'subpath traversal' do
    it 'refuses an encoded traversal and never calls evo-flow' do
      grant_permissions('campaigns.read')

      get '/api/v1/campaigns/c1/%2e%2e/%2e%2e/segments'

      expect(response).to have_http_status(:bad_request)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end

    it 'refuses a dot segment, which would reach the action under another permission' do
      grant_permissions('campaigns.read', 'campaigns.update', 'campaigns.create')

      post '/api/v1/campaigns/c1/execute/.', params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end
  end

  describe 'evo-flow errors' do
    it 'answers 502, not 401, when evo-flow refuses the service call' do
      grant_permissions('campaigns.read')
      stub_request(:get, "#{api_url}/campaigns")
        .to_return(status: 401, body: { code: 'TENANT_REQUIRED' }.to_json, headers: json)

      get '/api/v1/campaigns'

      expect(response).to have_http_status(:bad_gateway)
    end

    it 'relays any other evo-flow status' do
      grant_permissions('campaigns.update')
      stub_request(:patch, "#{api_url}/campaigns/c1")
        .to_return(status: 422, body: { message: 'invalid' }.to_json, headers: json)

      patch '/api/v1/campaigns/c1', params: { title: '' }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'permission mapping per method + subpath' do
    def expect_denied
      expect(response).to have_http_status(:forbidden)
      expect(a_request(:any, /evo-flow\.test/)).not_to have_been_made
    end

    it 'denies a read without campaigns.read' do
      grant_permissions('campaigns.create', 'campaigns.update')
      get '/api/v1/campaigns/c1/stats'
      expect_denied
    end

    it 'denies a create without campaigns.create' do
      grant_permissions('campaigns.read', 'campaigns.update')
      post '/api/v1/campaigns', params: { title: 'x' }, as: :json
      expect_denied
    end

    it 'denies an update without campaigns.update' do
      grant_permissions('campaigns.read', 'campaigns.create')
      patch '/api/v1/campaigns/c1', params: { title: 'y' }, as: :json
      expect_denied
    end

    it 'denies a delete without campaigns.delete' do
      grant_permissions('campaigns.read', 'campaigns.update')
      delete '/api/v1/campaigns/c1'
      expect_denied
    end

    {
      'schedule' => 'campaigns.schedule', 'execute' => 'campaigns.execute', 'pause' => 'campaigns.pause',
      'resume' => 'campaigns.resume', 'stop' => 'campaigns.stop', 'execution/cancel' => 'campaigns.stop',
      'duplicate' => 'campaigns.duplicate'
    }.each do |action, permission|
      it "demands #{permission} for POST /campaigns/:id/#{action}, not campaigns.update" do
        grant_permissions('campaigns.read', 'campaigns.update', 'campaigns.create')
        post "/api/v1/campaigns/c1/#{action}", params: {}, as: :json
        expect_denied
      end

      it "forwards POST /campaigns/:id/#{action} with #{permission} alone" do
        grant_permissions(permission)
        stub = stub_request(:post, "#{api_url}/campaigns/c1/#{action}")
               .to_return(status: 200, body: { data: { id: 'c1' } }.to_json, headers: json)

        post "/api/v1/campaigns/c1/#{action}", params: {}, as: :json

        expect(response).to have_http_status(:ok)
        expect(stub).to have_been_requested
      end
    end

    it 'demands campaigns.bulk_action for POST /campaigns/bulk-action' do
      grant_permissions('campaigns.read', 'campaigns.update', 'campaigns.create', 'campaigns.delete')
      post '/api/v1/campaigns/bulk-action', params: { action: 'delete', campaign_ids: %w[c1] }, as: :json
      expect_denied
    end

    it 'demands the key of the action a bulk applies, on top of campaigns.bulk_action' do
      grant_permissions('campaigns.bulk_action', 'campaigns.update')
      post '/api/v1/campaigns/bulk-action', params: { action: 'delete', campaign_ids: %w[c1] }, as: :json
      expect_denied
    end

    it 'forwards a bulk action, its action key included, with both permissions' do
      grant_permissions('campaigns.bulk_action', 'campaigns.delete')
      stub = stub_request(:post, "#{api_url}/campaigns/bulk-action")
             .with(body: { action: 'delete', campaign_ids: %w[c1] }.to_json)
             .to_return(status: 200, body: { data: { affected_count: 1 } }.to_json, headers: json)

      post '/api/v1/campaigns/bulk-action', params: { action: 'delete', campaign_ids: %w[c1] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested
    end
  end
end
