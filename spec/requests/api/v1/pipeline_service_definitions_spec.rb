# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::PipelineServiceDefinitionsController, type: :controller do
  let(:user) { User.create!(email: 'spec-user@example.com', name: 'Spec User') }
  let(:pipeline) do
    Pipeline.create!(name: 'Sales Pipeline', pipeline_type: 'sales', created_by: user)
  end

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'

    # Bypass authentication and authorization
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
  end

  after do
    Current.reset
  end

  describe 'GET #index' do
    let!(:service_a) do
      pipeline.pipeline_service_definitions.create!(
        name: 'Consulting', default_value: 200.00, currency: 'BRL'
      )
    end

    let!(:service_b) do
      pipeline.pipeline_service_definitions.create!(
        name: 'Support', default_value: 100.00, currency: 'BRL'
      )
    end

    let!(:inactive_service) do
      pipeline.pipeline_service_definitions.create!(
        name: 'Deprecated', default_value: 50.00, currency: 'BRL', active: false
      )
    end

    it 'returns active service definitions ordered by name' do
      get :index, params: { pipeline_id: pipeline.id }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data.length).to eq(2)
      expect(data.first['name']).to eq('Consulting')
      expect(data.last['name']).to eq('Support')
    end

    it 'excludes inactive service definitions' do
      get :index, params: { pipeline_id: pipeline.id }

      names = JSON.parse(response.body)['data'].map { |d| d['name'] }
      expect(names).not_to include('Deprecated')
    end

    it 'returns correct serialized fields' do
      get :index, params: { pipeline_id: pipeline.id }

      first = JSON.parse(response.body)['data'].first
      expect(first).to include(
        'id', 'pipeline_id', 'name',
        'default_value', 'currency', 'active',
        'formatted_default_value', 'created_at', 'updated_at'
      )
      expect(first['default_value']).to eq(200.0)
      expect(first['formatted_default_value']).to eq('200,00')
    end
  end

  describe 'GET #show' do
    let!(:service_def) do
      pipeline.pipeline_service_definitions.create!(
        name: 'Consulting', default_value: 250.50, currency: 'BRL', description: 'Hourly consulting'
      )
    end

    it 'returns a single service definition' do
      get :show, params: { pipeline_id: pipeline.id, id: service_def.id }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data['name']).to eq('Consulting')
      expect(data['default_value']).to eq(250.5)
      expect(data['currency']).to eq('BRL')
      expect(data['description']).to eq('Hourly consulting')
      expect(data['formatted_default_value']).to eq('250,50')
    end

    it 'returns 404 for non-existent definition' do
      get :show, params: { pipeline_id: pipeline.id, id: '00000000-0000-0000-0000-000000000000' }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST #create' do
    let(:valid_params) do
      {
        pipeline_id: pipeline.id,
        service_definition: {
          name: 'New Service',
          default_value: 150.00,
          currency: 'USD',
          description: 'A new service'
        }
      }
    end

    it 'creates a service definition' do
      expect do
        post :create, params: valid_params
      end.to change(PipelineServiceDefinition, :count).by(1)

      expect(response).to have_http_status(:created)
      data = JSON.parse(response.body)['data']
      expect(data['name']).to eq('New Service')
      expect(data['default_value']).to eq(150.0)
      expect(data['currency']).to eq('USD')
      expect(data['pipeline_id']).to eq(pipeline.id)
    end

    it 'rejects duplicate name in same pipeline' do
      pipeline.pipeline_service_definitions.create!(
        name: 'New Service', default_value: 100, currency: 'BRL'
      )

      post :create, params: valid_params

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects missing name' do
      post :create, params: {
        pipeline_id: pipeline.id,
        service_definition: { default_value: 100, currency: 'BRL' }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects invalid currency' do
      post :create, params: {
        pipeline_id: pipeline.id,
        service_definition: { name: 'Test', default_value: 100, currency: 'GBP' }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects negative default_value' do
      post :create, params: {
        pipeline_id: pipeline.id,
        service_definition: { name: 'Test', default_value: -10, currency: 'BRL' }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PATCH #update' do
    let!(:service_def) do
      pipeline.pipeline_service_definitions.create!(
        name: 'Original', default_value: 100.00, currency: 'BRL'
      )
    end

    it 'updates the service definition' do
      patch :update, params: {
        pipeline_id: pipeline.id,
        id: service_def.id,
        service_definition: { name: 'Updated', default_value: 200.00 }
      }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data['name']).to eq('Updated')
      expect(data['default_value']).to eq(200.0)
    end

    it 'rejects invalid update' do
      patch :update, params: {
        pipeline_id: pipeline.id,
        id: service_def.id,
        service_definition: { default_value: -10 }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'DELETE #destroy' do
    let!(:service_def) do
      pipeline.pipeline_service_definitions.create!(
        name: 'To Deactivate', default_value: 100.00, currency: 'BRL'
      )
    end

    it 'soft-deletes (deactivates) the service definition' do
      delete :destroy, params: { pipeline_id: pipeline.id, id: service_def.id }

      expect(response).to have_http_status(:no_content)
      expect(service_def.reload.active).to be false
    end

    it 'does not hard-delete the record' do
      expect do
        delete :destroy, params: { pipeline_id: pipeline.id, id: service_def.id }
      end.not_to change(PipelineServiceDefinition, :count)
    end
  end
end
