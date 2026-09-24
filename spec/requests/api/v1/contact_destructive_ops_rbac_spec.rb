# frozen_string_literal: true

require 'rails_helper'

# Destructive contact operations must be permission-gated: merging (which
# destroys the mergee) and contact bulk actions (delete-only today) demand
# contacts.delete; conversation bulk actions demand conversations.update;
# notes and label tagging demand contacts.update, with contacts.read for reads.
RSpec.describe 'Contact destructive operations RBAC', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }
  let(:contact) { Contact.create!(name: "Contact #{SecureRandom.hex(3)}") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'POST /api/v1/actions/contact_merge' do
    let(:mergee) { Contact.create!(name: "Mergee #{SecureRandom.hex(3)}") }

    it 'denies a user without contacts.delete' do
      grant_permissions('contacts.read', 'contacts.update')

      post '/api/v1/actions/contact_merge',
           params: { base_contact_id: contact.id, mergee_contact_id: mergee.id }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Contact.exists?(mergee.id)).to be(true)
    end

    it 'merges for a user with contacts.delete' do
      grant_permissions('contacts.delete')

      post '/api/v1/actions/contact_merge',
           params: { base_contact_id: contact.id, mergee_contact_id: mergee.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(Contact.exists?(mergee.id)).to be(false)
    end
  end

  describe 'POST /api/v1/bulk_actions' do
    it 'denies a Contact bulk delete without contacts.delete' do
      grant_permissions('contacts.read', 'contacts.update')

      post '/api/v1/bulk_actions', params: { type: 'Contact', ids: [contact.id] }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Contact.exists?(contact.id)).to be(true)
    end

    it 'performs a Contact bulk delete with contacts.delete' do
      grant_permissions('contacts.delete')

      post '/api/v1/bulk_actions', params: { type: 'Contact', ids: [contact.id] }, as: :json

      expect(response).to have_http_status(:created)
      expect(Contact.exists?(contact.id)).to be(false)
    end

    it 'denies a Conversation bulk action without conversations.update' do
      grant_permissions('contacts.read', 'contacts.update', 'contacts.delete')

      post '/api/v1/bulk_actions', params: { type: 'Conversation', ids: [] }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'performs a Conversation bulk action with conversations.update' do
      grant_permissions('conversations.update')

      post '/api/v1/bulk_actions', params: { type: 'Conversation', ids: [] }, as: :json

      expect(response).to have_http_status(:created)
    end
  end

  describe '/api/v1/contacts/:contact_id/notes' do
    let!(:note) { Note.create!(content: 'existing', contact: contact, user: user) }

    context 'without contacts.update' do
      before { grant_permissions('contacts.read') }

      it 'denies create, update and destroy but keeps reads' do
        post "/api/v1/contacts/#{contact.id}/notes", params: { note: { content: 'new' } }, as: :json
        expect(response).to have_http_status(:forbidden)

        patch "/api/v1/contacts/#{contact.id}/notes/#{note.id}", params: { note: { content: 'edit' } }, as: :json
        expect(response).to have_http_status(:forbidden)

        delete "/api/v1/contacts/#{contact.id}/notes/#{note.id}", as: :json
        expect(response).to have_http_status(:forbidden)
        expect(note.reload.content).to eq('existing')

        get "/api/v1/contacts/#{contact.id}/notes", as: :json
        expect(response).to have_http_status(:ok)

        get "/api/v1/contacts/#{contact.id}/notes/#{note.id}", as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    context 'with contacts.update' do
      before { grant_permissions('contacts.read', 'contacts.update') }

      it 'allows the full CRUD' do
        post "/api/v1/contacts/#{contact.id}/notes", params: { note: { content: 'new' } }, as: :json
        expect(response).to have_http_status(:created)

        patch "/api/v1/contacts/#{contact.id}/notes/#{note.id}", params: { note: { content: 'edit' } }, as: :json
        expect(response).to have_http_status(:ok)
        expect(note.reload.content).to eq('edit')

        delete "/api/v1/contacts/#{contact.id}/notes/#{note.id}", as: :json
        expect(response).to have_http_status(:ok)
        expect(Note.exists?(note.id)).to be(false)
      end
    end
  end

  describe '/api/v1/contacts/:contact_id/labels' do
    it 'denies tagging without contacts.update but keeps the label list readable' do
      grant_permissions('contacts.read')

      post "/api/v1/contacts/#{contact.id}/labels", params: { labels: ['vip'] }, as: :json
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/contacts/#{contact.id}/labels", as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to eq([])
      expect(json_response['payload']).to eq([])
    end

    it 'tags with contacts.update' do
      grant_permissions('contacts.read', 'contacts.update')

      post "/api/v1/contacts/#{contact.id}/labels", params: { labels: ['vip'] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to eq(['vip'])
      expect(json_response['payload']).to eq(['vip'])
    end
  end
end
