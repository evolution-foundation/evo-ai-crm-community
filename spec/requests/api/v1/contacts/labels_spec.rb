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
      expect(json_response['payload']).to contain_exactly('vip')
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
      expect(json_response['payload']).to contain_exactly('vip')
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly('vip')
    end

    it 'persists a tagging when the label name arrives as a bare scalar under labels' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: 'support' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('support')
      expect(taggings_for(contact).count).to eq(1)
    end

    it 'translates a UUID that matches a Label into its title and persists it' do
      label = Label.create!(title: 'Priority') # stored downcased as 'priority'

      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: [label.id] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('priority')
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
      expect(json_response['payload']).to contain_exactly(orphan_uuid)
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
      expect(json_response['payload']).to contain_exactly('support')
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly('support')
    end

    it 'reflects the persisted label on the subsequent index read' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labelId: 'support' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      get "/api/v1/contacts/#{contact.id}/labels", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('support')
    end
  end

  # CRM-212 follow-up: `POST .../labels` replaces the full set, so a caller
  # that only knows the label it wants to add/remove (e.g. the AI's own
  # manage_conversation_labels tool) had to GET the current list, merge
  # locally, then POST the full result back. That read-then-replace is not
  # atomic: a concurrent removal (an operator turning off `atendimento_ia`
  # mid-turn) landing between the tool's GET and POST gets silently
  # overwritten, re-adding the label the operator just removed. These atomic
  # endpoints let a caller add/remove a single label without ever reading
  # the current set first, closing that race.
  describe 'POST /api/v1/contacts/:contact_id/labels/add' do
    it 'adds a label without disturbing existing labels' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['vip'] }, headers: headers, as: :json

      post "/api/v1/contacts/#{contact.id}/labels/add",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip', 'atendimento_ia')
      expect(contact.reload.label_list).to contain_exactly('vip', 'atendimento_ia')
    end

    it 'is idempotent when the label is already present' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['atendimento_ia'] }, headers: headers, as: :json

      post "/api/v1/contacts/#{contact.id}/labels/add",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(taggings_for(contact).count).to eq(1)
    end
  end

  describe 'POST /api/v1/contacts/:contact_id/labels/remove' do
    it 'removes a single label without disturbing the others, with no prior read' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: %w[vip atendimento_ia] }, headers: headers, as: :json

      post "/api/v1/contacts/#{contact.id}/labels/remove",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip')
      expect(contact.reload.label_list).to contain_exactly('vip')
    end

    it 'is a no-op when the label is not present' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['vip'] }, headers: headers, as: :json

      post "/api/v1/contacts/#{contact.id}/labels/remove",
           params: { labelId: 'atendimento_ia' }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip')
    end
  end
end
