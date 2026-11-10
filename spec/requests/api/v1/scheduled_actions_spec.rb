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
  let(:pipeline) { Pipeline.create!(name: "Cards #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    Current.user = user
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def create_card(contact = Contact.create!(name: "Card #{SecureRandom.hex(3)}"))
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

  describe 'card-scoped actions' do
    let(:card) { create_card(maria_silva) }
    # Same leading characters as the card: the legacy bigint column reads both as one number.
    let(:lookalike_id) { "#{card.id[0, 8]}-0000-4000-8000-000000000000" }

    def post_action(**target)
      Current.user = user
      post '/api/v1/scheduled_actions',
           params: { scheduled_action: { contact_id: maria_silva.id, action_type: 'execute_webhook',
                                         scheduled_for: 1.hour.from_now.iso8601,
                                         payload: { webhook_url: 'https://example.com/hook' }, **target } },
           headers: headers, as: :json
    end

    it 'keeps the whole uuid of the card in pipeline_item_id' do
      post_action(pipeline_item_id: card.id)

      expect(response).to have_http_status(:created)
      expect(json_response['data']['pipeline_item_id']).to eq(card.id)
    end

    it 'still accepts and lists the legacy numeric deal_id' do
      post_action(deal_id: 42)
      expect(response).to have_http_status(:created)

      get '/api/v1/scheduled_actions/by_deal/42', headers: headers

      expect(json_response['data'].pluck('deal_id')).to eq([42])
    end

    it 'lists by the card uuid the actions linked to that card, not to a lookalike' do
      own = create_action(pipeline_item_id: card.id)
      create_action(pipeline_item_id: create_card.id)

      get "/api/v1/scheduled_actions/by_deal/#{card.id}", headers: headers
      expect(json_response['data'].pluck('id')).to eq([own.id])

      get "/api/v1/scheduled_actions/by_deal/#{lookalike_id}", headers: headers
      expect(json_response['data']).to be_empty
    end

    it 'refuses a card that does not exist or is not a uuid' do
      [lookalike_id, '3571'].each do |pipeline_item_id|
        post_action(pipeline_item_id: pipeline_item_id)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it 'refuses a card in a pipeline the creator cannot open' do
      owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner')
      private_pipeline = Pipeline.create!(name: 'Private', pipeline_type: 'sales', created_by: owner, visibility: :private)
      private_card = PipelineItem.create!(pipeline: private_pipeline, contact: maria_silva,
                                          pipeline_stage: private_pipeline.pipeline_stages.create!(name: 'New', position: 1))

      action = ScheduledAction.new(pipeline_item_id: private_card.id, contact: maria_silva, action_type: 'execute_webhook',
                                   scheduled_for: 1.hour.from_now, created_by: user.id,
                                   payload: { 'webhook_url' => 'https://example.com/hook' })

      expect(action).not_to be_valid
      expect(action.errors[:pipeline_item_id]).to be_present
    end
  end
end
