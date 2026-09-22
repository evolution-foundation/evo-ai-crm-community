# frozen_string_literal: true

require 'rails_helper'

# EVO-1897 (D8) + EVO-1928: `POST /api/v1/contacts/:contact_id/labels` must
# persist a tagging whenever the caller expresses a label by NAME, including the
# shapes used by the journeys/evo-flow add-label node (a flat `labels` array, a
# singular `labelId` key, and/or a bare scalar value). It previously replied
# `200` with no tagging persisted — a false-success — for every shape other than
# a flat `labels` array, and also silently dropped UUID-shaped tokens that did
# not resolve to a local Label. The node authenticates server-side with the
# service token, so the request is exercised through that path here.
RSpec.describe 'Api::V1::Contacts::Labels', type: :request do
  let(:contact) { Contact.create!(name: "Repro #{SecureRandom.hex(3)}", type: 'person') }
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

  def taggings_for(record)
    ActsAsTaggableOn::Tagging.where(taggable: record)
  end

  describe 'POST /api/v1/contacts/:contact_id/labels' do
    it 'persists a tagging when labels are sent as a titles array' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['vip'] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('vip')
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly('vip')
    end

    # Regression for EVO-1928: the add-label node posts the label by NAME under
    # the singular `labelId` key. The previous `params.permit(labels: [])` made
    # that resolve to nil, so no tagging was persisted.
    it 'persists a tagging when the label name arrives under the singular labelId key' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labelId: 'vip' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('vip')
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly('vip')
    end

    it 'persists a tagging when the label name arrives as a bare scalar under labels' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: 'support' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('support')
      expect(taggings_for(contact).count).to eq(1)
    end

    it 'translates a UUID that matches a Label into its title and persists it' do
      label = Label.create!(title: 'Priority') # stored downcased as 'priority'

      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: [label.id] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('priority')
      expect(taggings_for(contact).count).to eq(1)
    end

    # Regression (EVO-1897 D8): a UUID-shaped token that does not resolve to a
    # Label row was silently dropped, so `update_labels([])` wiped the list and
    # replied 200 with no tagging persisted — the false-success reported in D8.
    it 'still persists a tagging when a UUID does not match any Label' do
      orphan_uuid = SecureRandom.uuid

      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: [orphan_uuid] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly(orphan_uuid)
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly(orphan_uuid)
    end

    it 'removes a label by re-posting the desired set without it' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: %w[vip support] }, headers: headers, as: :json
      expect(taggings_for(contact).count).to eq(2)

      # The contact labels endpoint replaces the full set; the node drops a
      # label by posting the remaining desired set.
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['support'] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('support')
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly('support')
    end

    it 'replaces the whole set, dropping labels absent from the request' do
      contact.update_labels(%w[vip support])

      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['lead'] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('lead')
      expect(contact.reload.label_list).to contain_exactly('lead')
    end

    it 'reflects the persisted label on the subsequent index read' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labelId: 'support' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      get "/api/v1/contacts/#{contact.id}/labels", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('support')
    end
  end

  describe 'GET /api/v1/contacts/:contact_id/labels' do
    it 'answers in the standard envelope' do
      contact.update_labels(%w[vip support])

      get "/api/v1/contacts/#{contact.id}/labels", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['success']).to be(true)
      expect(json_response['data']).to contain_exactly('vip', 'support')
      expect(json_response).not_to have_key('payload')
      expect(json_response['meta']).to include('timestamp')
    end

    # The reported loss: a client read `data`, found nothing under the old
    # shape, and posted back an empty set.
    it 'returns what a client needs to post the set back unchanged' do
      contact.update_labels(%w[vip support])

      get "/api/v1/contacts/#{contact.id}/labels", headers: headers, as: :json
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: json_response['data'] }, headers: headers, as: :json

      expect(contact.reload.label_list).to contain_exactly('vip', 'support')
    end
  end

  describe 'POST /api/v1/contacts/:contact_id/labels/add' do
    it 'adds the labels without touching the existing ones' do
      contact.update_labels(%w[vip])

      post "/api/v1/contacts/#{contact.id}/labels/add",
           params: { labels: %w[support vip] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('vip', 'support')
      expect(contact.reload.label_list).to contain_exactly('vip', 'support')
    end

    it 'resolves a label id to its title' do
      label = Label.create!(title: 'Priority')
      contact.update_labels(%w[vip])

      post "/api/v1/contacts/#{contact.id}/labels/add",
           params: { labels: [label.id] }, headers: headers, as: :json

      expect(contact.reload.label_list).to contain_exactly('vip', 'priority')
    end

    it 'rejects a request without labels instead of answering success' do
      contact.update_labels(%w[vip])

      post "/api/v1/contacts/#{contact.id}/labels/add",
           params: {}, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['success']).to be(false)
      expect(json_response['error']).to include('code' => 'MISSING_REQUIRED_FIELD', 'details' => include('field' => 'labels'))
      expect(contact.reload.label_list).to contain_exactly('vip')
    end
  end

  describe 'POST /api/v1/contacts/:contact_id/labels/remove' do
    it 'removes only the labels sent' do
      contact.update_labels(%w[vip support lead])

      post "/api/v1/contacts/#{contact.id}/labels/remove",
           params: { labels: %w[support] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to contain_exactly('vip', 'lead')
      expect(contact.reload.label_list).to contain_exactly('vip', 'lead')
    end

    it 'removes a label sent in a different case' do
      contact.update_labels(%w[vip lead])

      post "/api/v1/contacts/#{contact.id}/labels/remove",
           params: { labelId: 'VIP' }, headers: headers, as: :json

      expect(json_response['data']).to contain_exactly('lead')
      expect(contact.reload.label_list).to contain_exactly('lead')
    end

    it 'ignores a label the contact does not have' do
      contact.update_labels(%w[vip])

      post "/api/v1/contacts/#{contact.id}/labels/remove",
           params: { labelId: 'missing' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(contact.reload.label_list).to contain_exactly('vip')
    end

    it 'rejects a request without labels instead of answering success' do
      contact.update_labels(%w[vip])

      post "/api/v1/contacts/#{contact.id}/labels/remove",
           params: { labels: [] }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(contact.reload.label_list).to contain_exactly('vip')
    end
  end
end
