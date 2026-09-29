# frozen_string_literal: true

require 'rails_helper'
require 'zip'
require 'stringio'

# templates.export and templates.import are not a way around a category's own
# permission: exporting reads the category, importing creates in it. Each side asks
# the same key the category's own endpoint asks.
RSpec.describe 'Template bundles honour each category permission', type: :request do
  let(:caller_user) { User.create!(name: 'Caller', email: "cat-#{SecureRandom.hex(4)}@example.com") }

  def login_as(user, *granted, read_all_inboxes: true)
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
    nil
  end

  def inventory
    get '/api/v1/templates/exportable_inventory', as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body['data']
  end

  def export(selection)
    post '/api/v1/templates/export', params: { template_name: 'T', selection: selection }, as: :json
    expect(response).to have_http_status(:ok)
    response.body
  end

  def import(categories)
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
    post '/api/v1/templates/import', params: { bundle_file: Rack::Test::UploadedFile.new(io, 'application/zip', original_filename: 'b.zip') }
    expect(response).to have_http_status(:ok)
    response.parsed_body.dig('data', 'items').index_by { |item| item['slug'] }
  end

  describe 'export' do
    let!(:inbox) { Inbox.create!(name: 'sales-desk', channel: Channel::Api.create!(webhook_url: 'https://desk.example.com/hook')) }
    let!(:agent) { AgentBot.create!(name: 'Helper bot') }
    let!(:label) { Label.create!(title: 'vip') }
    let!(:template) { MessageTemplate.create!(name: 'welcome', channel: inbox.channel, content: 'Hi') }

    {
      'inboxes' => 'inboxes.read',
      'agents' => 'agent_bots.read',
      'labels' => 'labels.read'
    }.each do |category, key|
      context "without #{key}" do
        let(:everything) { %w[inboxes.read agent_bots.read labels.read message_templates.read] - [key] }
        let(:record_id) { { 'inboxes' => inbox, 'agents' => agent, 'labels' => label }[category].id }

        it 'leaves the category out of the inventory' do
          login_as(caller_user, 'templates.export', *everything)
          expect(inventory).not_to have_key(category)
        end

        it 'leaves it out of the bundle, whether asked for all or by id' do
          login_as(caller_user, 'templates.export', *everything)
          expect(category_in_bundle(export(category => { all: true }), category)).to be_nil
          expect(category_in_bundle(export(category => { ids: [record_id] }), category)).to be_nil
        end
      end

      it "exports #{category} with #{key}" do
        login_as(caller_user, 'templates.export', key)
        expect(inventory).to have_key(category)
        expect(category_in_bundle(export(category => { all: true }), category)).to be_present
      end
    end

    it 'does not name the inbox of an exported message template without inboxes.read' do
      login_as(caller_user, 'templates.export', 'message_templates.read')
      exported = category_in_bundle(export('message_templates' => { ids: [template.id] }), 'message_templates')
      expect(exported.first).to include('name' => 'welcome', 'inbox_slug' => nil)
    end

    it 'names it with inboxes.read' do
      login_as(caller_user, 'templates.export', 'message_templates.read', 'inboxes.read')
      exported = category_in_bundle(export('message_templates' => { ids: [template.id] }), 'message_templates')
      expect(exported.first['inbox_slug']).to eq('sales-desk')
    end
  end

  describe 'import' do
    let(:bundle) do
      {
        'labels' => [{ 'slug' => 'l', 'title' => "imported-#{SecureRandom.hex(3)}", 'color' => '#fff' }],
        'inboxes' => [{ 'slug' => 'i', 'name' => 'imported-desk', 'channel_type' => 'Channel::Api', 'channel_attributes' => {} }],
        'agents' => [{ 'slug' => 'a', 'name' => 'Imported bot' }],
        'macros' => [{ 'slug' => 'm', 'name' => 'Imported macro', 'visibility' => 'personal', 'actions' => [] }],
        'message_templates' => [{ 'slug' => 't', 'name' => 'imported-template', 'inbox_slug' => 'i', 'content' => 'Hi' }]
      }
    end
    let(:creates) { %w[labels.create inboxes.create agent_bots.create macros.manage message_templates.manage] }

    {
      'labels' => ['labels.create', 'l', -> { Label.where('title LIKE ?', 'imported-%') }],
      'inboxes' => ['inboxes.create', 'i', -> { Inbox.where(name: 'imported-desk') }],
      'agents' => ['agent_bots.create', 'a', -> { AgentBot.where(name: 'Imported bot') }],
      'macros' => ['macros.manage', 'm', -> { Macro.where(name: 'Imported macro') }],
      'message_templates' => ['message_templates.manage', 't', -> { MessageTemplate.where(name: 'imported-template') }]
    }.each do |category, (key, slug, created)|
      it "skips #{category} without #{key}, says why, and imports the rest" do
        login_as(caller_user, 'templates.import', *(creates - [key]))
        items = import(bundle)

        expect(items[slug]).to include('category' => category, 'status' => 'skipped', 'reason' => "missing permission #{key}")
        expect(instance_exec(&created)).to be_empty
        others = items.except(slug).values
        others = others.reject { |item| item['category'] == 'message_templates' } if category == 'inboxes'
        expect(others.map { |item| item['status'] }).to all(eq('created'))
      end
    end

    it 'imports every category the caller may create' do
      login_as(caller_user, 'templates.import', *creates)
      expect(import(bundle).values.map { |item| item['status'] }).to all(eq('created'))
    end

    it 'leaves a message template whose inbox was skipped out as well' do
      login_as(caller_user, 'templates.import', *(creates - ['inboxes.create']))
      expect(import(bundle)['t']['status']).to eq('skipped')
      expect(MessageTemplate.where(name: 'imported-template')).to be_empty
    end
  end
end
