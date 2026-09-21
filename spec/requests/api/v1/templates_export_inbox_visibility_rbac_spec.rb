# frozen_string_literal: true

require 'rails_helper'
require 'zip'
require 'stringio'

# An inbox has per-user visibility: a user reads the inboxes they are a member of,
# unless they are an administrator or hold conversations.read_all. The export
# enumerated every inbox regardless. Each of its three enumeration paths
# (inventory, `all`, explicit id) has its own example, because a fix that lands in
# one and misses another still leaks.
RSpec.describe 'Template export inbox visibility scope', type: :request do
  let(:exporter) { User.create!(name: 'Exporter', email: "exp-#{SecureRandom.hex(4)}@example.com") }

  let!(:member_inbox) { Inbox.create!(name: 'Member inbox', channel: Channel::Api.create!(webhook_url: 'https://member.example.com/hook')) }
  let!(:foreign_inbox) { Inbox.create!(name: 'Foreign inbox', channel: Channel::Api.create!(webhook_url: 'https://foreign.example.com/hook')) }

  before { InboxMember.create!(user: exporter, inbox: member_inbox) }

  def login_as(user, *granted, read_all_inboxes: false)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      Current.evo_permission_cache ||= {}
      Current.evo_can_read_all_inboxes = read_all_inboxes
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      granted.include?(permission)
    end
  end

  after { Current.reset }

  def category_in_bundle(zip_binary, category)
    Zip::InputStream.open(StringIO.new(zip_binary)) do |io|
      while (entry = io.get_next_entry)
        return JSON.parse(io.read) if entry.name == "#{category}.json"
      end
    end
    []
  end

  def inventory_inbox_ids
    get '/api/v1/templates/exportable_inventory', as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body.dig('data', 'inboxes').map { |inbox| inbox['id'] }
  end

  # The bundle carries the inbox name as a slug.
  def exported_inbox_names(selection)
    post '/api/v1/templates/export', params: { template_name: 'T', selection: { inboxes: selection } }, as: :json
    expect(response).to have_http_status(:ok)
    category_in_bundle(response.body, 'inboxes').map { |inbox| inbox['name'] }
  end

  # --- path 1: the inventory the wizard renders -------------------------------

  describe 'GET /api/v1/templates/exportable_inventory' do
    it 'lists the inboxes the caller is a member of, never the others' do
      login_as(exporter, 'templates.export')

      ids = inventory_inbox_ids

      expect(ids).to include(member_inbox.id)
      expect(ids).not_to include(foreign_inbox.id)
    end

    it 'lists none for a caller with no membership: there is no zero-membership fallback' do
      loner = User.create!(name: 'Loner', email: "loner-#{SecureRandom.hex(4)}@example.com")
      login_as(loner, 'templates.export')

      expect(inventory_inbox_ids).to be_empty
    end

    it 'lists every inbox for an administrator' do
      allow(exporter).to receive(:administrator?).and_return(true)
      login_as(exporter, 'templates.export')

      expect(inventory_inbox_ids).to match_array(Inbox.pluck(:id))
    end

    it 'lists every inbox for a caller holding conversations.read_all' do
      login_as(exporter, 'templates.export', read_all_inboxes: true)

      expect(inventory_inbox_ids).to match_array(Inbox.pluck(:id))
    end
  end

  describe 'POST /api/v1/templates/export' do
    # --- path 2: selection `all` ---------------------------------------------

    it 'with `all`, the bundle carries the member inbox, not the foreign one' do
      login_as(exporter, 'templates.export')

      names = exported_inbox_names(all: true)

      expect(names).to include('member-inbox')
      expect(names).not_to include('foreign-inbox')
    end

    # --- path 3: an explicit id, crafted from a leaked UUID --------------------

    it 'ignores an explicit id of an inbox the caller is not a member of' do
      login_as(exporter, 'templates.export')

      names = exported_inbox_names(ids: [foreign_inbox.id, member_inbox.id])

      expect(names).to eq(['member-inbox'])
    end

    # The bundle is a zip: the settings are read from the JSON inside it, and the
    # member inbox proves they would show if the scope let them through.
    it 'does not hand over the channel settings of an inbox the caller cannot read' do
      login_as(exporter, 'templates.export')

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { inboxes: { ids: [foreign_inbox.id, member_inbox.id] } } },
           as: :json

      exported = category_in_bundle(response.body, 'inboxes').to_json
      expect(exported).to include('member.example.com')
      expect(exported).not_to include('foreign.example.com')
    end

    it 'carries every inbox for a caller holding conversations.read_all, with `all` and by explicit id' do
      login_as(exporter, 'templates.export', read_all_inboxes: true)

      expect(exported_inbox_names(all: true)).to match_array(Inbox.pluck(:name).map(&:parameterize))
      expect(exported_inbox_names(ids: [foreign_inbox.id])).to eq(['foreign-inbox'])
    end

    it 'carries an explicit id of any inbox for an administrator' do
      allow(exporter).to receive(:administrator?).and_return(true)
      login_as(exporter, 'templates.export')

      expect(exported_inbox_names(ids: [foreign_inbox.id])).to eq(['foreign-inbox'])
    end

    it 'carries every inbox for an administrator' do
      allow(exporter).to receive(:administrator?).and_return(true)
      login_as(exporter, 'templates.export')

      expect(exported_inbox_names(all: true)).to match_array(Inbox.pluck(:name).map(&:parameterize))
    end

    # --- the over-scoping guard ----------------------------------------------

    # Catches the opposite error: over-scoping would silently drop account-wide
    # assets from every bundle, and no test of the leak itself would notice.
    it 'leaves the account-wide categories fully exportable' do
      login_as(exporter, 'templates.export')
      Label.create!(title: "shared-#{SecureRandom.hex(3)}")
      Team.create!(name: "Squad #{SecureRandom.hex(3)}")

      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { labels: { all: true }, teams: { all: true } } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(category_in_bundle(response.body, 'labels').length).to eq(Label.count)
      expect(category_in_bundle(response.body, 'teams').length).to eq(Team.count)
    end
  end

  # --- the inbox named from inside another category ----------------------------

  # A message template is a shared asset and stays exportable by anyone holding
  # templates.export. The inbox it is linked to is referenced by NAME, and that name
  # is the datum the inbox rule protects.
  describe 'the inbox a message template is linked to' do
    let!(:member_template) do
      MessageTemplate.create!(name: "member-tpl-#{SecureRandom.hex(3)}", content: 'Oi', channel: member_inbox.channel)
    end
    let!(:foreign_template) do
      MessageTemplate.create!(name: "foreign-tpl-#{SecureRandom.hex(3)}", content: 'Oi', channel: foreign_inbox.channel)
    end

    def exported_inbox_slugs
      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { message_templates: { ids: [member_template.id, foreign_template.id] } } },
           as: :json
      expect(response).to have_http_status(:ok)
      category_in_bundle(response.body, 'message_templates').to_h { |tpl| [tpl['name'], tpl['inbox_slug']] }
    end

    it 'names the inbox the caller can read, and not the one it cannot' do
      login_as(exporter, 'templates.export')

      slugs = exported_inbox_slugs

      expect(slugs[member_template.name]).to eq('member-inbox')
      expect(slugs).to have_key(foreign_template.name)
      expect(slugs[foreign_template.name]).to be_nil
    end

    it 'names both for an administrator' do
      allow(exporter).to receive(:administrator?).and_return(true)
      login_as(exporter, 'templates.export')

      expect(exported_inbox_slugs.values).to contain_exactly('member-inbox', 'foreign-inbox')
    end
  end

  # --- the userless callers: the export delegates, it does not decide ----------

  describe 'userless callers follow the inbox rule' do
    it 'lists no inbox for a bare userless caller, and does not raise' do
      Current.reset

      expect(Templates::ExportService.exportable_inventory(current_user: nil)['inboxes']).to eq([])
    end

    it 'lists every inbox for a service token, as InboxPolicy#show? answers for it' do
      Current.reset
      Current.service_authenticated = true

      ids = Templates::ExportService.exportable_inventory(current_user: nil)['inboxes'].pluck(:id)

      expect(ids).to match_array(Inbox.pluck(:id))
    end
  end

  # --- the router and the rule it delegates to ---------------------------------

  describe 'Templates::VisibilityScope' do
    it 'delegates inboxes to the rule every other inbox read goes through' do
      expect(Templates::VisibilityScope.for('inboxes', Inbox, exporter).pluck(:id))
        .to match_array(exporter.assigned_inboxes.pluck(:id))
    end

    it 'hands the remaining account-wide categories their untouched relation' do
      %w[labels teams agents canned_responses message_templates custom_attributes].each do |category|
        model = Templates::BundleBuilder::MODEL_MAP[category]
        expect(Templates::VisibilityScope.for(category, model, exporter).to_sql).to eq(model.all.to_sql)
      end
    end
  end

  describe 'InboxPolicy::Scope' do
    def resolve(user:, service_authenticated: nil)
      InboxPolicy::Scope.new({ user: user, service_authenticated: service_authenticated }, Inbox).resolve
    end

    it "resolves to the user's assigned inboxes" do
      expect(resolve(user: exporter).pluck(:id)).to eq([member_inbox.id])
    end

    it 'resolves to no inbox without a user' do
      expect(resolve(user: nil)).to be_empty
    end

    it 'resolves to every inbox for a service-authenticated caller' do
      expect(resolve(user: nil, service_authenticated: true).pluck(:id)).to match_array(Inbox.pluck(:id))
    end
  end
end
