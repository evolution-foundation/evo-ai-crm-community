# frozen_string_literal: true

require 'rails_helper'
require 'zip'
require 'stringio'

# CRM-205 — the template export read macros unscoped, so a templates.export holder
# reached another user's PERSONAL macro by exporting it. Every macro enumeration in
# the export path (inventory, `all`, explicit id) now asks Macro.with_visibility,
# the same scope the member actions ask since CRM-195 — including its answer for a
# userless caller, which the export must not second-guess.
RSpec.describe 'Template export macro visibility scope (CRM-205)', type: :request do
  let(:exporter) { User.create!(name: 'Exporter', email: "exp-#{SecureRandom.hex(4)}@example.com") }
  let(:other_user) { User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com") }

  let!(:own_personal) do
    Macro.create!(name: 'Exporter personal', visibility: :personal, created_by_id: exporter.id, actions: [])
  end
  let!(:global_macro) do
    Macro.create!(name: 'Team global', visibility: :global, created_by_id: other_user.id, actions: [])
  end
  let!(:foreign_personal) do
    Macro.create!(name: 'Foreign personal', visibility: :personal, created_by_id: other_user.id, actions: [])
  end

  def login_as(user, *granted)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      # Visibility is under test here, not the category permission: grant every read.
      granted.include?(permission) || Templates::CategoryPermission::READ.value?(permission)
    end
  end

  after { Current.reset }

  # Pull the parsed <category>.json array out of an in-memory bundle ZIP, or [] if
  # the bundle carries no entry for that category.
  def category_in_bundle(zip_binary, category)
    Zip::InputStream.open(StringIO.new(zip_binary)) do |io|
      while (entry = io.get_next_entry)
        return JSON.parse(io.read) if entry.name == "#{category}.json"
      end
    end
    []
  end

  def macros_in_bundle(zip_binary)
    category_in_bundle(zip_binary, 'macros')
  end

  describe 'GET /api/v1/templates/exportable_inventory' do
    it "lists the caller's own personal + globals, never another user's personal macro" do
      login_as(exporter, 'templates.export')

      get '/api/v1/templates/exportable_inventory', as: :json

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig('data', 'macros').map { |m| m['id'] }
      expect(ids).to include(own_personal.id, global_macro.id)
      expect(ids).not_to include(foreign_personal.id)
    end
  end

  describe 'POST /api/v1/templates/export' do
    it "with `all`, the bundle carries the caller's own personal + globals, not another user's personal" do
      login_as(exporter, 'templates.export')

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { macros: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      names = macros_in_bundle(response.body).map { |m| m['name'] }
      expect(names).to include('Exporter personal', 'Team global')
      expect(names).not_to include('Foreign personal')
    end

    it "ignores an explicit id crafted from another user's personal macro (defense in depth)" do
      login_as(exporter, 'templates.export')

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { macros: { ids: [foreign_personal.id, own_personal.id] } } },
           as: :json

      expect(response).to have_http_status(:ok)
      names = macros_in_bundle(response.body).map { |m| m['name'] }
      expect(names).to include('Exporter personal')
      expect(names).not_to include('Foreign personal')
    end

    it 'denies the whole export without templates.export' do
      login_as(exporter) # no keys

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { macros: { all: true } } }, as: :json

      # TemplatesController gates via require_permissions, which answers 403 (not the
      # Pundit 401 that pipeline/macros member actions return).
      expect(response).to have_http_status(:forbidden)
    end

    # Catches the opposite error: a base_relation that scoped the account-wide
    # categories too would silently drop shared assets from every bundle.
    it 'leaves account-wide categories (labels) fully exportable' do
      login_as(exporter, 'templates.export')
      Label.create!(title: "shared-#{SecureRandom.hex(3)}")

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { labels: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      # The lone label lands in the bundle even though it has no per-user owner.
      expect(category_in_bundle(response.body, 'labels').length).to eq(1)
    end
  end

  # A service token is with_visibility's call, not the export's: it gets everything, as
  # check_permission! already lets it in. A bare userless caller holds no permission, so
  # the category gate refuses it before with_visibility is asked.
  describe 'userless callers follow with_visibility' do
    # A bare userless caller holds no permission, so the category gate refuses it before
    # the category's own rule is asked; only the service token below reaches that rule.
    it 'leaves macros out for a bare userless caller, and does not raise' do
      Current.reset

      expect(Templates::ExportService.exportable_inventory(current_user: nil)).not_to have_key('macros')
    end

    it 'lists every macro for a service token, matching what the model grants it' do
      Current.reset
      Current.service_authenticated = true

      names = Templates::ExportService.exportable_inventory(current_user: nil)['macros'].pluck(:name)

      expect(names).to match_array(Macro.with_visibility(nil, {}).pluck(:name))
      expect(names).to include('Foreign personal')
    end
  end
end
