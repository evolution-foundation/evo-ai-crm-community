# frozen_string_literal: true

require 'rails_helper'

# The auth resolves which permission keys an API access token may exercise and
# sends them with the validation; the CRM bounds the request by them as well as
# by the user.
RSpec.describe 'API access token scopes', type: :request do
  let(:user) { User.create!(email: "token-user-#{SecureRandom.hex(4)}@example.com", name: 'Token User') }
  let(:raw_token) { SecureRandom.hex(32) }
  let(:headers) { { 'api_access_token' => raw_token } }
  let(:auth_service) { instance_double(EvoAuthService) }

  def validation_for(scopes:, effective_scopes:)
    {
      'user' => { 'id' => user.id, 'email' => user.email, 'role' => { 'key' => 'agent' } },
      'token' => { 'type' => 'api_access_token', 'scopes' => scopes, 'effective_scopes' => effective_scopes }
    }
  end

  before do
    Rails.cache.clear
    allow(EvoAuthService).to receive(:new).and_return(auth_service)
    # The user holds every permission: only the token can deny.
    EvoExtensionPoints.replace(:permission_resolver) { |**| true }
  end

  after do
    EvoExtensionPoints.reset!
    Current.reset
  end

  it 'denies an endpoint the token scopes leave out and serves one they grant' do
    allow(auth_service).to receive(:validate_token)
      .and_return(validation_for(scopes: 'labels.read', effective_scopes: %w[labels.read dashboard.read]))

    get '/api/v1/contacts', headers: headers
    expect(response).to have_http_status(:forbidden)

    get '/api/v1/labels', headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'keeps a default-scoped token bounded by the user alone' do
    allow(auth_service).to receive(:validate_token)
      .and_return(validation_for(scopes: 'default', effective_scopes: []))

    get '/api/v1/contacts', headers: headers

    expect(response).to have_http_status(:ok)
  end
end
