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

  describe 'GET /api/v1/assistant_insights/waiting_conversations' do
    let(:member_inbox) { Inbox.create!(name: 'Suporte', channel: Channel::WebWidget.create!(website_url: 'https://a.example.com')) }
    let(:other_inbox) { Inbox.create!(name: 'Vendas', channel: Channel::WebWidget.create!(website_url: 'https://b.example.com')) }

    before { InboxMember.create!(inbox: member_inbox, user: viewer) }

    # Conversation creation reopens the status and stamps waiting_since, so both are set after.
    def conversation_in(inbox, waiting_hours:, status: :open, **attrs)
      contact = Contact.create!(name: "Cliente #{SecureRandom.hex(3)}")
      contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(6))
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, **attrs)
      conversation.update_columns(status: Conversation.statuses[status], waiting_since: waiting_hours&.hours&.ago)
      conversation
    end

    def waiting_for(user, **params)
      get '/api/v1/assistant_insights/waiting_conversations',
          params: { user_id: user.id, **params }, headers: headers
      response.parsed_body.dig('data', 'waiting_count')
    end

    it 'counts open conversations waiting past the threshold in the inboxes the user is in' do
      2.times { conversation_in(member_inbox, waiting_hours: 30) }
      conversation_in(member_inbox, waiting_hours: 2)
      conversation_in(other_inbox, waiting_hours: 30)

      expect(waiting_for(viewer)).to eq(2)
    end

    it 'leaves out answered, resolved and archived conversations' do
      conversation_in(member_inbox, waiting_hours: nil)
      conversation_in(member_inbox, waiting_hours: 30, status: :resolved)
      conversation_in(member_inbox, waiting_hours: 30, custom_attributes: { 'archived' => true })

      expect(waiting_for(viewer)).to eq(0)
    end

    it 'honors a custom threshold' do
      conversation_in(member_inbox, waiting_hours: 5)

      expect(waiting_for(viewer, hours: 4)).to eq(1)
    end

    context 'when the user holds conversations.read_all' do
      let(:granted) { %w[conversations.read conversations.read_all] }

      it 'counts every inbox' do
        conversation_in(member_inbox, waiting_hours: 30)
        conversation_in(other_inbox, waiting_hours: 30)

        expect(waiting_for(viewer)).to eq(2)
      end
    end

    context 'when the user lacks conversations.read' do
      let(:granted) { [] }

      it 'counts nothing' do
        conversation_in(member_inbox, waiting_hours: 30)

        expect(waiting_for(viewer)).to eq(0)
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
