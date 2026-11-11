# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Procedures', type: :request do
  let(:user) { User.create!(email: "procedure-rbac-#{SecureRandom.hex(4)}@example.com", name: 'Procedure RBAC') }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  def procedure_payload(title: 'Troca de titularidade', usage_mode: 'both')
    {
      procedure: {
        title: title,
        description: 'Validar documentos e orientar o cliente',
        category: 'Suporte',
        tags: %w[titularidade documentos],
        usage_mode: usage_mode,
        content_blocks: [
          { id: 'heading-1', type: 'heading', text: 'Antes de iniciar' },
          { id: 'step-1', type: 'checklist', text: 'Confirmar CPF/CNPJ', checked: false }
        ],
        visibility: [
          { scope_type: 'all', scope_id: nil },
          { scope_type: 'public_link', scope_id: nil }
        ],
        targets: [
          { target_type: 'label', target_id: SecureRandom.uuid }
        ]
      }
    }
  end

  describe 'POST /api/v1/procedures' do
    it 'creates a procedure with rich blocks, visibility and targets' do
      post '/api/v1/procedures', params: procedure_payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      data = json_response['data']
      expect(data['title']).to eq('Troca de titularidade')
      expect(data['status']).to eq('draft')
      expect(data['content_blocks'].size).to eq(2)
      expect(data['visibility'].map { |item| item['scope_type'] }).to include('all', 'public_link')
      expect(data['targets'].first['target_type']).to eq('label')
    end

    it 'ignores status in payload so create cannot bypass publish permission' do
      payload = procedure_payload
      payload[:procedure][:status] = 'published'

      post '/api/v1/procedures', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response.dig('data', 'status')).to eq('draft')
    end

    it 'denies create without procedures.create' do
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
        Current.user = user
        Current.evo_permission_cache ||= {}
      end
      allow_any_instance_of(Api::V1::ProceduresController).to receive(:has_user_permission?) do |_controller, _user_id, permission|
        permission == 'procedures.read'
      end

      post '/api/v1/procedures', params: procedure_payload, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET /api/v1/procedures' do
    it 'searches and paginates active procedures' do
      procedure = Procedure.create!(
        title: 'Cancelamento de contrato',
        description: 'Retencao',
        category: 'Financeiro',
        status: :published,
        usage_mode: :internal,
        content_blocks: []
      )
      procedure.procedure_visibilities.create!(scope_type: 'all')

      get '/api/v1/procedures', params: { search: 'contrato', per_page: 1 }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |item| item['id'] }).to include(procedure.id)
      expect(json_response.dig('meta', 'pagination', 'page_size')).to eq(1)
    end

    it 'does not expose public tokens in regular read responses' do
      procedure = Procedure.create!(
        title: 'Somente link publico',
        status: :published,
        usage_mode: :customer,
        public_token: SecureRandom.urlsafe_base64(24),
        content_blocks: []
      )
      procedure.procedure_visibilities.create!(scope_type: 'all')
      procedure.procedure_visibilities.create!(scope_type: 'public_link')

      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
        Current.user = user
        Current.evo_permission_cache ||= {}
      end
      allow_any_instance_of(Api::V1::ProceduresController).to receive(:has_user_permission?) do |_controller, _user_id, permission|
        permission == 'procedures.read'
      end

      get '/api/v1/procedures', headers: { 'Authorization' => 'Bearer token' }

      expect(response).to have_http_status(:ok)
      serialized = json_response['data'].find { |item| item['id'] == procedure.id }
      expect(serialized).to be_present
      expect(serialized).not_to have_key('public_token')
    end
  end

  describe 'POST /api/v1/procedures/:id/publish' do
    it 'publishes and generates a token when public link visibility exists' do
      post '/api/v1/procedures', params: procedure_payload(title: 'Publicar manual'), headers: headers, as: :json
      id = json_response.dig('data', 'id')

      post "/api/v1/procedures/#{id}/publish", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('published')
      expect(json_response.dig('data', 'public_token')).to be_present
    end
  end

  describe 'GET /api/v1/procedures/public/:token' do
    it 'returns a published customer-shareable procedure by token without authentication' do
      procedure = Procedure.create!(
        title: 'Manual do cliente',
        status: :published,
        usage_mode: :customer,
        public_token: SecureRandom.urlsafe_base64(24),
        content_blocks: [{ id: 'step-1', type: 'paragraph', text: 'Siga as instrucoes' }]
      )
      procedure.procedure_visibilities.create!(scope_type: 'public_link')

      get "/api/v1/procedures/public/#{procedure.public_token}"

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'title')).to eq('Manual do cliente')
      expect(json_response.dig('data', 'public_token')).to be_nil
    end
  end

  describe 'POST /api/v1/procedures/:id/send_to_conversation' do
    it 'blocks customer share for internal-only procedures' do
      post '/api/v1/procedures',
           params: procedure_payload(title: 'Somente interno', usage_mode: 'internal'),
           headers: headers,
           as: :json
      id = json_response.dig('data', 'id')

      post "/api/v1/procedures/#{id}/send_to_conversation",
           params: { conversation_id: SecureRandom.uuid },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
