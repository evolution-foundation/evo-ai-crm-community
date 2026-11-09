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
  let(:pipeline) { Pipeline.create!(name: "Deals #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    Current.user = user
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def create_deal(contact = Contact.create!(name: "Deal #{SecureRandom.hex(3)}"))
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact)
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
    let!(:action_without_contact) { create_action(deal_id: create_deal.id) }

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

  describe 'deal-scoped actions' do
    let(:deal) { create_deal(maria_silva) }
    # Same leading digits as the deal: the old bigint column read both as one number.
    let(:lookalike_id) { "#{deal.id[0, 8]}-0000-4000-8000-000000000000" }

    it 'keeps the whole uuid of the deal the action was created for' do
      post '/api/v1/scheduled_actions',
           params: { scheduled_action: { deal_id: deal.id, contact_id: maria_silva.id, action_type: 'execute_webhook',
                                         scheduled_for: 1.hour.from_now.iso8601,
                                         payload: { webhook_url: 'https://example.com/hook' } } },
           headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response['data']['deal_id']).to eq(deal.id)
      expect(ScheduledAction.last.deal_id).to eq(deal.id)
    end

    it 'lists by deal only the actions of that deal' do
      own = create_action(deal_id: deal.id)
      create_action(deal_id: create_deal.id)

      get "/api/v1/scheduled_actions/by_deal/#{deal.id}", headers: headers

      expect(json_response['data'].pluck('id')).to eq([own.id])

      get "/api/v1/scheduled_actions/by_deal/#{lookalike_id}", headers: headers

      expect(json_response['data']).to be_empty
    end

    it 'lists nothing for a malformed deal id instead of every action without a deal' do
      create_action(contact: maria_silva)

      get '/api/v1/scheduled_actions/by_deal/3571', headers: headers

      expect(json_response['data']).to be_empty
    end

    it 'refuses a deal that does not exist or is not a uuid' do
      [lookalike_id, '3571'].each do |deal_id|
        # The request resets Current, and the service-token create reads its user.
        Current.user = user
        post '/api/v1/scheduled_actions',
             params: { scheduled_action: { deal_id: deal_id, contact_id: maria_silva.id, action_type: 'execute_webhook',
                                           scheduled_for: 1.hour.from_now.iso8601,
                                           payload: { webhook_url: 'https://example.com/hook' } } },
             headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(ScheduledAction.where(contact: maria_silva)).to be_empty
    end
  end
end
