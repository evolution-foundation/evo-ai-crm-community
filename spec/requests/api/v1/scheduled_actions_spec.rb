# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Scheduled actions', type: :request do
  let(:user) { User.create!(email: "sa-#{SecureRandom.hex(4)}@example.com", name: 'Scheduler') }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  let(:maria_silva) { Contact.create!(name: 'Maria Silva', email: "maria-#{SecureRandom.hex(4)}@example.com") }
  let(:ana_maria) { Contact.create!(name: 'Ana Maria Souza', email: "ana-#{SecureRandom.hex(4)}@example.com") }
  let(:joao) { Contact.create!(name: 'João Pereira', email: "joao-#{SecureRandom.hex(4)}@example.com") }
  let(:percent) { Contact.create!(name: 'Desconto 100%', email: "pct-#{SecureRandom.hex(4)}@example.com") }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    Current.user = user
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def create_action(**target)
    ScheduledAction.create!(
      action_type: 'execute_webhook', scheduled_for: 1.hour.from_now, created_by: user.id,
      payload: { 'webhook_url' => 'https://example.com/hook' }, **target
    )
  end

  def json_response
    response.parsed_body
  end

  describe 'GET /api/v1/scheduled_actions' do
    let!(:maria_actions) { [create_action(contact: maria_silva), create_action(contact: maria_silva)] }
    let!(:ana_action) { create_action(contact: ana_maria) }
    let!(:joao_action) { create_action(contact: joao) }
    let!(:percent_action) { create_action(contact: percent) }
    let!(:action_without_contact) { create_action(deal_id: 42) }

    it 'lists only the actions whose contact name matches the search, case-insensitively' do
      get '/api/v1/scheduled_actions', params: { search: 'maria' }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].pluck('id')).to match_array((maria_actions + [ana_action]).map(&:id))
      expect(json_response['meta']['pagination']['total']).to eq(3)
    end

    it 'counts the filtered total across pages' do
      get '/api/v1/scheduled_actions', params: { search: 'Maria', page: 1, per_page: 2 }, headers: headers

      expect(json_response['data'].size).to eq(2)
      expect(json_response['meta']['pagination']['total']).to eq(3)
      expect(json_response['meta']['pagination']['total_pages']).to eq(2)
    end

    it 'lists every action when the search is empty or blank' do
      ['', '   '].each do |search|
        get '/api/v1/scheduled_actions', params: { search: search }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response['meta']['pagination']['total']).to eq(6)
        expect(json_response['data'].pluck('id')).to include(action_without_contact.id)
      end
    end

    it 'leaves out actions without a contact when searching' do
      get '/api/v1/scheduled_actions', params: { search: 'a' }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].pluck('id')).to match_array((maria_actions + [ana_action, joao_action]).map(&:id))
      expect(json_response['meta']['pagination']['total']).to eq(4)
    end

    it 'treats LIKE wildcards in the search as literal text' do
      get '/api/v1/scheduled_actions', params: { search: '%' }, headers: headers

      expect(json_response['data'].pluck('id')).to eq([percent_action.id])
      expect(json_response['meta']['pagination']['total']).to eq(1)
    end
  end
end
