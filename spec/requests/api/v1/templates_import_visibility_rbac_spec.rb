# frozen_string_literal: true

require 'rails_helper'
require 'zip'
require 'stringio'

# The import report says whether a name collided (`renamed`) or not (`created`).
# For the categories a caller reads only in part — inboxes, macros, pipelines — that
# answer must not depend on records the caller cannot read, or the report confirms
# the names the export already stopped handing out.
RSpec.describe 'Template import collision scope', type: :request do
  let(:importer) { User.create!(name: 'Importer', email: "imp-#{SecureRandom.hex(4)}@example.com") }
  let(:other_user) { User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com") }

  def login_as(user, read_all_inboxes: false)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      Current.evo_permission_cache ||= {}
      Current.evo_can_read_all_inboxes = read_all_inboxes
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      permission == 'templates.import'
    end
  end

  after { Current.reset }

  def build_bundle(categories)
    manifest = { schema_version: 1, name: 'T', description: '', author: 'spec', created_at: Time.now.iso8601, contents: {} }
    io = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry('manifest.json')
      zip.write(manifest.to_json)
      categories.each do |category, items|
        zip.put_next_entry("#{category}.json")
        zip.write(items.to_json)
      end
    end
    io.rewind
    io
  end

  def import(categories)
    file = Rack::Test::UploadedFile.new(build_bundle(categories), 'application/zip', original_filename: 'b.zip')
    post '/api/v1/templates/import', params: { bundle_file: file }
    expect(response).to have_http_status(:ok)
    response.parsed_body.dig('data', 'items').index_by { |item| item['slug'] }
  end

  def expect_untouched(item, name)
    expect(item).to include('status' => 'created', 'new_name' => name)
    expect(item).not_to have_key('original_name')
  end

  def expect_renamed(item, name)
    expect(item).to include('status' => 'renamed', 'new_name' => "#{name} (Template T)")
  end

  describe 'inboxes' do
    before do
      member_inbox = Inbox.create!(name: 'member-desk', channel: Channel::Api.create!(webhook_url: 'https://member.example.com/hook'))
      Inbox.create!(name: 'foreign-desk', channel: Channel::Api.create!(webhook_url: 'https://foreign.example.com/hook'))
      InboxMember.create!(user: importer, inbox: member_inbox)
    end

    # Inbox names are stored sanitized, and that stored form is what an export writes.

    def inbox_item(slug, name)
      { 'slug' => slug, 'name' => name, 'channel_type' => 'Channel::Api', 'channel_attributes' => {} }
    end

    def bundle
      { 'inboxes' => [inbox_item('foreign', 'foreign-desk'), inbox_item('member', 'member-desk'), inbox_item('fresh', 'fresh-desk')] }
    end

    it 'reports an inbox the caller is not a member of exactly like a name nobody holds' do
      login_as(importer)
      items = import(bundle)

      expect_untouched(items['foreign'], 'foreign-desk')
      expect_untouched(items['fresh'], 'fresh-desk')
      expect_renamed(items['member'], 'member-desk')
    end

    it 'renames against every inbox for an administrator' do
      allow(importer).to receive(:administrator?).and_return(true)
      login_as(importer)
      items = import(bundle)

      expect_renamed(items['foreign'], 'foreign-desk')
      expect_untouched(items['fresh'], 'fresh-desk')
    end

    it 'renames against every inbox for a holder of conversations.read_all' do
      login_as(importer, read_all_inboxes: true)

      expect_renamed(import(bundle)['foreign'], 'foreign-desk')
    end
  end

  describe 'macros' do
    before do
      Macro.create!(name: 'Own personal', visibility: :personal, created_by_id: importer.id, actions: [])
      Macro.create!(name: 'Shared global', visibility: :global, created_by_id: other_user.id, actions: [])
      Macro.create!(name: 'Foreign personal', visibility: :personal, created_by_id: other_user.id, actions: [])
    end

    def macro_item(slug, name)
      { 'slug' => slug, 'name' => name, 'visibility' => 'personal', 'actions' => [] }
    end

    it 'reports another user\'s personal macro exactly like a name nobody holds' do
      login_as(importer)
      items = import('macros' => [
                       macro_item('foreign', 'Foreign personal'), macro_item('own', 'Own personal'),
                       macro_item('global', 'Shared global'), macro_item('fresh', 'Fresh macro')
                     ])

      expect_untouched(items['foreign'], 'Foreign personal')
      expect_untouched(items['fresh'], 'Fresh macro')
      expect_renamed(items['own'], 'Own personal')
      expect_renamed(items['global'], 'Shared global')
    end
  end

  # A pipeline name is unique across the table, so a collision with a pipeline the
  # caller cannot read has to be avoided, not ignored. Every imported pipeline is
  # therefore suffixed, and the report reads the same whatever already exists.
  describe 'pipelines' do
    before do
      Pipeline.create!(name: 'Foreign private', visibility: :private, created_by: other_user)
      Pipeline.create!(name: 'Shared public', visibility: :public, created_by: other_user)
    end

    def pipeline_item(slug, name)
      { 'slug' => slug, 'name' => name, 'pipeline_type' => 'custom', 'visibility' => 'private', 'stages' => [] }
    end

    it 'reports the same for an unreadable, a readable and an unused name' do
      login_as(importer)
      items = import('pipelines' => [
                       pipeline_item('foreign', 'Foreign private'), pipeline_item('public', 'Shared public'),
                       pipeline_item('fresh', 'Fresh funnel')
                     ])

      expect_renamed(items['foreign'], 'Foreign private')
      expect_renamed(items['public'], 'Shared public')
      expect_renamed(items['fresh'], 'Fresh funnel')
      expect(Pipeline.where(name: 'Fresh funnel (Template T)', created_by: importer)).to exist
    end

    # Looking only among readable pipelines here would hand the create a name the
    # table already holds, and the whole import would fail.
    it 'steps past a suffixed name held by an unreadable pipeline instead of failing' do
      Pipeline.create!(name: 'Fresh funnel (Template T)', visibility: :private, created_by: other_user)
      login_as(importer)
      items = import('pipelines' => [pipeline_item('fresh', 'Fresh funnel')])

      expect(items['fresh']).to include('status' => 'renamed', 'new_name' => 'Fresh funnel (Template T) (2)')
    end
  end

  # Account-wide categories are read in full by anyone who imports, so a collision
  # there is the caller's own knowledge and still renames.
  describe 'account-wide categories' do
    before { Team.create!(name: 'Shared team') }

    it 'still renames a colliding team' do
      login_as(importer)
      items = import('teams' => [{ 'slug' => 'team', 'name' => 'Shared team' }])

      expect_renamed(items['team'], 'Shared team')
    end
  end
end
