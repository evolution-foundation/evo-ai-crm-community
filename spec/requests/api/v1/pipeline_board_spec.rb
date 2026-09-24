# frozen_string_literal: true

require 'rails_helper'

# The board of a large funnel: GET /pipelines/:id and GET /pipelines/:id/pipeline_items
# must cost the same number of queries whatever the number of cards, and the item list
# must always be paged.
RSpec.describe 'Pipeline board', type: :request do
  let(:user) { User.create!(name: 'Board Owner', email: "board-#{SecureRandom.hex(4)}@example.com") }
  let(:agent) { User.create!(name: 'Agent Smith', email: "agent-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Board #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:first_stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let!(:second_stage) { pipeline.pipeline_stages.create!(name: 'Won', position: 2) }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://board.example.com') }
  let(:inbox) { Inbox.create!(name: 'Board Inbox', channel: channel) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:show?).and_return(true)
  end

  after { Current.reset }

  def json_response
    response.parsed_body
  end

  def conversation_card(stage: first_stage, name: 'Maria', phone: nil, services: nil, **conversation_attrs)
    contact = Contact.create!(name: name, phone_number: phone || "+5511#{SecureRandom.random_number(10**9).to_s.rjust(9, '9')}")
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, **conversation_attrs)
    3.times do |i|
      Message.create!(conversation: conversation, inbox: inbox, message_type: :incoming,
                      content: "message #{i}", sender: contact)
    end
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation,
                         custom_fields: services ? { 'services' => services } : {})
  end

  def lead_card(stage: first_stage, name: 'Lead', phone: nil)
    contact = Contact.create!(name: name, phone_number: phone || "+5521#{SecureRandom.random_number(10**9).to_s.rjust(9, '9')}")
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact)
  end

  def count_queries(&)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    queries
  end

  describe 'GET /pipelines/:id' do
    it 'answers only stages and their counters when include_items is false' do
      conversation_card(services: [{ 'name' => 'Setup', 'value' => '100.5' }])
      lead_card
      conversation_card(stage: second_stage).update!(completed_at: Time.current)

      get "/api/v1/pipelines/#{pipeline.id}", params: { include_items: false }

      expect(response).to have_http_status(:ok)
      stages = json_response['data']['stages']
      expect(stages.map { |stage| stage.key?('items') }).to eq([false, false])
      expect(stages.first).to include('item_count' => 2, 'active_item_count' => 2, 'active_total_value' => 100.5)
      expect(stages.second).to include('item_count' => 1, 'active_item_count' => 0, 'active_total_value' => 0)
      expect(json_response['data']['services_info']['total_value']).to eq(100.5)
    end

    it 'keeps every active card inline by default, with its latest message' do
      conversation_card
      lead_card

      get "/api/v1/pipelines/#{pipeline.id}"

      items = json_response['data']['stages'].first['items']
      expect(items.size).to eq(2)
      conversation_item = items.find { |item| item['type'] == 'conversation' }
      expect(conversation_item['conversation']['last_non_activity_message']['content']).to eq('message 2')
      expect(conversation_item['conversation']['unread_count']).to eq(3)
    end

    it 'runs the same number of queries for 2 and for 8 cards' do
      conversation_card
      lead_card
      small = count_queries { get "/api/v1/pipelines/#{pipeline.id}" }

      3.times { conversation_card }
      3.times { lead_card(stage: second_stage) }
      large = count_queries { get "/api/v1/pipelines/#{pipeline.id}" }

      expect(json_response['data']['stages'].sum { |stage| stage['items'].size }).to eq(8)
      expect(large).to eq(small)
    end
  end

  describe 'GET /pipelines/:id/pipeline_items' do
    let(:url) { "/api/v1/pipelines/#{pipeline.id}/pipeline_items" }

    it 'pages the cards and reports the page in meta' do
      5.times { lead_card }

      get url, params: { per_page: 2, page: 2 }

      expect(json_response['data'].size).to eq(2)
      expect(json_response['meta']['pagination']).to include('total' => 5, 'page' => 2, 'page_size' => 2,
                                                             'total_pages' => 3, 'has_next_page' => true)
    end

    it 'caps per_page at 100 and defaults to 50' do
      get url, params: { per_page: 1000 }
      expect(json_response['meta']['pagination']['page_size']).to eq(100)

      get url
      expect(json_response['meta']['pagination']['page_size']).to eq(50)
    end

    it 'never repeats a card across pages when cards share the sort value' do
      created_at = 1.hour.ago
      6.times { lead_card.update_columns(created_at: created_at) }

      ids = (1..3).flat_map do |page|
        get url, params: { per_page: 2, page: page }
        json_response['data'].pluck('id')
      end

      expect(ids.uniq.size).to eq(6)
    end

    it 'runs the same number of queries for 2 and for 8 cards' do
      conversation_card
      lead_card
      small = count_queries { get url, params: { view: 'card' } }

      3.times { conversation_card }
      3.times { lead_card(stage: second_stage) }
      large = count_queries { get url, params: { view: 'card' } }

      expect(json_response['data'].size).to eq(8)
      expect(large).to eq(small)
    end

    describe 'view=card' do
      it 'returns the card fields without the full contact' do
        item = conversation_card(name: 'Maria', phone: '+5511999887766', priority: :high, assignee: agent)

        get url, params: { view: 'card' }

        card = json_response['data'].first
        expect(card['id']).to eq(item.id)
        expect(card['contact'].keys).to match_array(%w[id name email phone_number])
        expect(card['contact']['phone_number']).to eq('+5511999887766')
        expect(card['conversation']).to include(
          'display_id' => item.conversation.display_id, 'status' => 'open', 'priority' => 'high',
          'assignee' => { 'id' => agent.id, 'name' => 'Agent Smith' },
          'inbox' => { 'id' => inbox.id, 'name' => inbox.name }
        )
        expect(card['conversation']).not_to have_key('custom_attributes')
      end

      it 'returns the labels, the latest message and the services of the card' do
        Label.create!(title: 'vip', color: '#00ff00', show_on_sidebar: true)
        conversation_card(cached_label_list: 'vip', services: [{ 'name' => 'Plan', 'value' => 50 }])

        get url, params: { view: 'card' }

        card = json_response['data'].first
        expect(card['conversation']['labels'].pluck('title')).to eq(['vip'])
        expect(card['conversation']['last_non_activity_message']['content']).to eq('message 2')
        expect(card['services_info']).to include('total_value' => 50.0, 'has_services' => true)
      end

      it 'returns the lead contact on a lead card' do
        lead_card(name: 'Joana', phone: '+5521988887777')

        get url, params: { view: 'card' }

        card = json_response['data'].first
        expect(card['contact']).to include('name' => 'Joana', 'phone_number' => '+5521988887777')
        expect(card).not_to have_key('conversation')
      end

      it 'masks the contact when the account masks contact PII' do
        allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
        conversation_card(phone: '+5511999887766')

        get url, params: { view: 'card' }

        expect(json_response['data'].first['contact']['phone_number']).not_to eq('+5511999887766')
      end
    end

    describe 'filters' do
      it 'searches lead and conversation cards by name, phone and display id' do
        lead = lead_card(name: 'Joana Lead', phone: '+5521988887777')
        conversation = conversation_card(name: 'Maria Deal')
        conversation_card(name: 'Someone Else')

        get url, params: { search: '98888' }
        expect(json_response['data'].pluck('id')).to eq([lead.id])

        get url, params: { search: 'maria' }
        expect(json_response['data'].pluck('id')).to eq([conversation.id])

        get url, params: { search: conversation.conversation.display_id.to_s }
        expect(json_response['data'].pluck('id')).to include(conversation.id)
      end

      it 'treats search wildcards literally' do
        lead_card(name: 'Plain')

        get url, params: { search: '%' }

        expect(json_response['data']).to be_empty
      end

      it 'filters by assignee, conversation status, priority and label' do
        Label.create!(title: 'VIP', color: '#00ff00', show_on_sidebar: true)
        assigned = conversation_card(assignee: agent)
        resolved = conversation_card.tap { |item| item.conversation.update_columns(status: Conversation.statuses[:resolved]) }
        urgent = conversation_card(priority: :urgent)
        labelled = conversation_card(cached_label_list: 'VIP')
        lead_card

        get url, params: { assignee_id: agent.id }
        expect(json_response['data'].pluck('id')).to eq([assigned.id])

        get url, params: { conversation_status: 'resolved' }
        expect(json_response['data'].pluck('id')).to eq([resolved.id])

        get url, params: { priority: 'urgent,high' }
        expect(json_response['data'].pluck('id')).to eq([urgent.id])

        get url, params: { label: 'vip' }
        expect(json_response['data'].pluck('id')).to eq([labelled.id])
      end

      it 'matches a label stored by id' do
        label = Label.create!(title: 'hot', color: '#ff0000', show_on_sidebar: true)
        labelled = conversation_card(cached_label_list: label.id)
        conversation_card

        get url, params: { label: 'hot' }

        expect(json_response['data'].pluck('id')).to eq([labelled.id])
      end

      it 'counts the filtered cards of a stage in meta' do
        2.times { conversation_card(assignee: agent) }
        conversation_card
        conversation_card(stage: second_stage, assignee: agent)

        get url, params: { stage_id: first_stage.id, assignee_id: agent.id, per_page: 1 }

        expect(json_response['meta']['pagination']['total']).to eq(2)
      end
    end
  end
end
