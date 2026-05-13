# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Contacts group filtering', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }
  after  { ENV.delete('EVOAI_CRM_API_TOKEN'); Current.reset }

  let!(:person)  { Contact.create!(name: 'Maria da Silva', email: 'maria@example.com', type: 'person') }
  let!(:company) { Contact.create!(name: 'Acme Corp', type: 'company') }
  let!(:group)   { Contact.create!(name: 'Almoço BH', identifier: '12345-9876@g.us', type: 'group') }

  def response_names
    JSON.parse(response.body).dig('data', 'payload')&.map { |c| c['name'] } ||
      JSON.parse(response.body)['data']&.map { |c| c['name'] } || []
  end

  describe 'GET /api/v1/contacts' do
    it 'excludes group contacts by default' do
      get '/api/v1/contacts', headers: headers
      expect(response).to have_http_status(:ok)
      names = response_names
      expect(names).to include('Maria da Silva', 'Acme Corp')
      expect(names).not_to include('Almoço BH')
    end

    it 'includes group contacts when include_groups=true' do
      get '/api/v1/contacts', params: { include_groups: 'true' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response_names).to include('Almoço BH')
    end

    it 'returns only group contacts when type=group' do
      get '/api/v1/contacts', params: { type: 'group' }, headers: headers
      expect(response).to have_http_status(:ok)
      names = response_names
      expect(names).to include('Almoço BH')
      expect(names).not_to include('Maria da Silva', 'Acme Corp')
    end
  end

  describe 'GET /api/v1/contacts/search' do
    it 'excludes group contacts from search results by default' do
      get '/api/v1/contacts/search', params: { q: 'Almoço' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response_names).not_to include('Almoço BH')
    end

    it 'includes group contacts in search when include_groups=true' do
      get '/api/v1/contacts/search', params: { q: 'Almoço', include_groups: 'true' }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response_names).to include('Almoço BH')
    end
  end
end
