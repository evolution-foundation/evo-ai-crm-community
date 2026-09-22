# frozen_string_literal: true

require 'rails_helper'

# The card owner was write-once and invisible: it was stamped from the session at
# creation, the update ignored it, and the serializer never emitted it — so a card that
# came in without an owner could not be fixed or even inspected through the API.
RSpec.describe 'Api::V1::PipelineItems owner', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:other_user) { User.create!(name: 'Colleague', email: "colleague-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@example.com") }
  let(:item) do
    pipeline.pipeline_items.create!(pipeline_stage: stage, contact: contact, entered_at: Time.current)
  end

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(true)
  end

  after { Current.reset }

  def patch_item(params)
    patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{item.id}", params: params, as: :json
    response.parsed_body
  end

  describe 'PATCH with assigned_by_id' do
    it 'assigns the card to another user' do
      body = patch_item(assigned_by_id: other_user.id)

      expect(response).to have_http_status(:success)
      expect(item.reload.assigned_by_id).to eq(other_user.id)
      expect(body['data']['assigned_by_id']).to eq(other_user.id)
      expect(body['data']['assigned_by']).to include('id' => other_user.id, 'name' => other_user.name)
    end

    it 'assigns a card that had no owner' do
      item.update!(assigned_by: nil)

      patch_item(assigned_by_id: other_user.id)

      expect(item.reload.assigned_by_id).to eq(other_user.id)
    end

    it 'clears the owner when the caller sends null' do
      item.update!(assigned_by: user)

      body = patch_item(assigned_by_id: nil)

      expect(response).to have_http_status(:success)
      expect(item.reload.assigned_by_id).to be_nil
      expect(body['data']['assigned_by_id']).to be_nil
      expect(body['data']).not_to have_key('assigned_by')
    end

    it 'refuses a user that does not exist and leaves the card untouched' do
      item.update!(assigned_by: user)
      missing_id = SecureRandom.uuid

      body = patch_item(assigned_by_id: missing_id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']['code']).to eq('VALIDATION_ERROR')
      expect(item.reload.assigned_by_id).to eq(user.id)
    end

    it 'counts as a change on its own, so the write is not rejected as a no-op' do
      body = patch_item(assigned_by_id: other_user.id)

      expect(response).to have_http_status(:success)
      expect(body['message']).to eq('Pipeline item updated successfully')
    end

    it 'leaves the owner alone when the payload omits the field' do
      item.update!(assigned_by: user)

      patch_item(notes: 'just a note')

      expect(item.reload.assigned_by_id).to eq(user.id)
    end
  end

  describe 'GET the item list' do
    it 'exposes the owner on each card' do
      item.update!(assigned_by: other_user)

      get "/api/v1/pipelines/#{pipeline.id}/pipeline_items"

      expect(response).to have_http_status(:success)
      card = response.parsed_body['data'].find { |i| i['id'] == item.id }
      expect(card['assigned_by_id']).to eq(other_user.id)
      expect(card['assigned_by']).to include('id' => other_user.id, 'email' => other_user.email)
    end
  end

  describe 'POST a new card' do
    it 'answers with the owner it stamped from the session' do
      new_contact = Contact.create!(name: 'Fresh', email: "fresh-#{SecureRandom.hex(4)}@example.com")

      post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
           params: { type: 'contact', item_id: new_contact.id, pipeline_stage_id: stage.id }, as: :json

      expect(response).to have_http_status(:created)
      data = response.parsed_body['data']
      expect(data['assigned_by_id']).to eq(user.id)
      expect(data['assigned_by']).to include('id' => user.id, 'name' => user.name)
    end
  end

  describe 'GET pipelines by_contact' do
    it 'exposes the owner on the contact\'s cards' do
      pipeline.update!(visibility: :public)
      item.update!(assigned_by: other_user)

      get "/api/v1/pipelines/by_contact/#{contact.id}"

      expect(response).to have_http_status(:success)
      cards = response.parsed_body['data'].flat_map { |p| p['stages'].to_a.flat_map { |s| s['items'].to_a } }
      card = cards.find { |i| i['id'] == item.id }
      expect(card['assigned_by']).to include('id' => other_user.id)
    end
  end
end
