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
    response.parsed_body['data'].map { |c| c['name'] }
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

  describe 'POST /api/v1/contacts with an identifier held by a hidden group' do
    def taken_error(field)
      response.parsed_body.dig('error', 'details').find { |e| e['field'] == field }
    end

    it 'points at the existing group so the client can update it instead of creating' do
      post '/api/v1/contacts', params: { name: 'Almoço BH', identifier: '12345-9876@g.us' }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(taken_error('identifier')['existing_contact']).to eq('id' => group.id, 'type' => 'group')
    end

    it 'points at the existing contact on a duplicated email regardless of case' do
      post '/api/v1/contacts', params: { name: 'Maria', email: 'MARIA@example.com' }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(taken_error('email')['existing_contact']).to eq('id' => person.id, 'type' => 'person')
    end

    it 'points at the existing group when an update takes its identifier' do
      put "/api/v1/contacts/#{person.id}", params: { identifier: '12345-9876@g.us' }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(taken_error('identifier')['existing_contact']).to eq('id' => group.id, 'type' => 'group')
    end

    context 'when the caller cannot read contacts' do
      let(:user) { User.create!(name: 'Creator', email: "creator-#{SecureRandom.hex(4)}@example.com") }

      before do
        ENV.delete('EVOAI_CRM_API_TOKEN')
        probe = user
        allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
          Current.user = probe
          Current.evo_permission_cache ||= {}
        end
        allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?) do |_, _, key|
          key != 'contacts.read'
        end
      end

      it 'reports the conflict without revealing the existing contact' do
        post '/api/v1/contacts', params: { name: 'Almoço BH', identifier: '12345-9876@g.us' }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(taken_error('identifier')).to include('messages' => ['has already been taken'])
        expect(taken_error('identifier')).not_to have_key('existing_contact')
      end
    end
  end
end
