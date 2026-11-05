# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::AssistantInsights', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:viewer) { User.create!(name: 'Viewer', email: "viewer-#{SecureRandom.hex(4)}@example.com") }
  let(:granted) { %w[pipelines.read conversations.read] }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    keys = granted
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission, **|
      keys.include?(permission)
    end
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def card_in(pipeline, stage, moved_days_ago:)
    card = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage,
                                contact: Contact.create!(name: "Lead #{SecureRandom.hex(3)}"))
    card.stage_movements.update_all(created_at: moved_days_ago.days.ago)
    card
  end

  describe 'GET /api/v1/assistant_insights/stale_pipeline_items' do
    let(:public_pipeline) { Pipeline.create!(name: 'Vendas', pipeline_type: 'sales', visibility: :public, created_by: owner) }
    let(:private_pipeline) { Pipeline.create!(name: 'Diretoria', pipeline_type: 'sales', visibility: :private, created_by: owner) }
    let(:public_stage) { PipelineStage.create!(pipeline: public_pipeline, name: 'Novo', position: 1) }
    let(:private_stage) { PipelineStage.create!(pipeline: private_pipeline, name: 'Novo', position: 1) }

    def stale_for(user, **params)
      get '/api/v1/assistant_insights/stale_pipeline_items',
          params: { user_id: user.id, **params }, headers: headers
      response.parsed_body.dig('data', 'pipelines').to_h { |row| [row['name'], row['stale_count']] }
    end

    it 'counts every stale card, past the size of one page of the board' do
      55.times { card_in(public_pipeline, public_stage, moved_days_ago: 10) }

      expect(stale_for(viewer)).to eq('Vendas' => 55)
    end

    it 'measures the time in the current stage, not the last edit of the card' do
      edited = card_in(public_pipeline, public_stage, moved_days_ago: 10)
      edited.update!(custom_fields: { 'note' => 'touched today' })
      card_in(public_pipeline, public_stage, moved_days_ago: 2)

      expect(stale_for(viewer)).to eq('Vendas' => 1)
    end

    it 'restarts the clock when the card changes stage' do
      card = card_in(public_pipeline, public_stage, moved_days_ago: 10)
      card.update!(pipeline_stage: PipelineStage.create!(pipeline: public_pipeline, name: 'Proposta', position: 2))

      expect(stale_for(viewer)).to eq({})
    end

    it 'leaves out completed cards and archived pipelines' do
      card_in(public_pipeline, public_stage, moved_days_ago: 10).update!(completed_at: 1.day.ago)
      archived = Pipeline.create!(name: 'Antigo', pipeline_type: 'sales', visibility: :public,
                                  created_by: owner, is_active: false)
      card_in(archived, PipelineStage.create!(pipeline: archived, name: 'Novo', position: 1), moved_days_ago: 10)

      expect(stale_for(viewer)).to eq({})
    end

    it "answers with the funnels the named user can see, not the service token's" do
      card_in(public_pipeline, public_stage, moved_days_ago: 10)
      card_in(private_pipeline, private_stage, moved_days_ago: 10)

      expect(stale_for(owner)).to eq('Diretoria' => 1, 'Vendas' => 1)
      expect(stale_for(viewer)).to eq('Vendas' => 1)
    end

    it 'honors a custom threshold' do
      card_in(public_pipeline, public_stage, moved_days_ago: 4)

      expect(stale_for(viewer, days: 3)).to eq('Vendas' => 1)
    end

    context 'when the user lacks pipelines.read' do
      let(:granted) { [] }

      it 'counts nothing' do
        card_in(public_pipeline, public_stage, moved_days_ago: 10)

        expect(stale_for(viewer)).to eq({})
      end
    end
  end

  describe 'access' do
    it 'refuses a call without the service token' do
      get '/api/v1/assistant_insights/stale_pipeline_items', params: { user_id: owner.id }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a signed-in user, who would otherwise read counts for someone else' do
      caller_user = viewer
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
        Current.user = caller_user
      end

      get '/api/v1/assistant_insights/stale_pipeline_items', params: { user_id: owner.id }

      expect(response).to have_http_status(:forbidden)
    end

    it 'answers 404 for an unknown user' do
      get '/api/v1/assistant_insights/stale_pipeline_items',
          params: { user_id: SecureRandom.uuid }, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
