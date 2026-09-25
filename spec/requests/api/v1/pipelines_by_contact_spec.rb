# frozen_string_literal: true

require 'rails_helper'

# by_contact filtered on contact_id alone, so it answered with the contact's lead cards
# and hid every opportunity the contact holds through one of its conversations —
# including a lead that was later promoted, which clears contact_id on the card.
RSpec.describe 'Api::V1::Pipelines by_contact', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) do
    Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales',
                     visibility: :public, created_by: user)
  end
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@example.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(4)}", channel: channel) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  after { Current.reset }

  def item_ids_for(contact_record)
    get "/api/v1/pipelines/by_contact/#{contact_record.id}"
    expect(response).to have_http_status(:success)

    response.parsed_body['data'].flat_map { |p| p['stages'].to_a.flat_map { |s| s['items'].to_a } }.pluck('id')
  end

  it 'returns the cards the contact holds through a conversation' do
    conversation_item = pipeline.pipeline_items.create!(
      pipeline_stage: stage, conversation: conversation, entered_at: Time.current
    )

    expect(item_ids_for(contact)).to include(conversation_item.id)
  end

  it 'still returns the contact-keyed lead cards' do
    lead_item = pipeline.pipeline_items.create!(pipeline_stage: stage, contact: contact, entered_at: Time.current)

    expect(item_ids_for(contact)).to include(lead_item.id)
  end

  it 'returns both kinds at once' do
    other_pipeline = Pipeline.create!(name: "Support #{SecureRandom.hex(3)}", pipeline_type: 'support',
                                      visibility: :public, created_by: user)
    other_stage = other_pipeline.pipeline_stages.create!(name: 'Open', position: 1)

    lead_item = pipeline.pipeline_items.create!(pipeline_stage: stage, contact: contact, entered_at: Time.current)
    conversation_item = other_pipeline.pipeline_items.create!(pipeline_stage: other_stage, conversation: conversation,
                                                              entered_at: Time.current)

    expect(item_ids_for(contact)).to contain_exactly(lead_item.id, conversation_item.id)
  end

  it 'leaves out another contact\'s cards' do
    other_contact = Contact.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com")
    other_inbox_contact = ContactInbox.create!(inbox: inbox, contact: other_contact, source_id: SecureRandom.hex(4))
    other_conversation = Conversation.create!(inbox: inbox, contact: other_contact,
                                              contact_inbox: other_inbox_contact)
    foreign_item = pipeline.pipeline_items.create!(
      pipeline_stage: stage, conversation: other_conversation, entered_at: Time.current
    )
    own_item = pipeline.pipeline_items.create!(pipeline_stage: stage, contact: contact, entered_at: Time.current)

    ids = item_ids_for(contact)

    expect(ids).to include(own_item.id)
    expect(ids).not_to include(foreign_item.id)
  end

  it 'answers with no pipelines when the contact holds no cards' do
    get "/api/v1/pipelines/by_contact/#{contact.id}"

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['data']).to eq([])
  end

  it 'reports a contact that does not exist' do
    get "/api/v1/pipelines/by_contact/#{SecureRandom.uuid}"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']['code']).to eq('CONTACT_NOT_FOUND')
  end

  context 'when the pipeline holds other contacts\' cards' do
    let!(:second_stage) { pipeline.pipeline_stages.create!(name: 'Won', position: 2) }
    let!(:conversation_item) do
      Message.create!(conversation: conversation, inbox: inbox, message_type: :incoming, content: 'hi', sender: contact)
      pipeline.pipeline_items.create!(pipeline_stage: stage, conversation: conversation, entered_at: Time.current)
    end
    let!(:lead_item) { pipeline.pipeline_items.create!(pipeline_stage: stage, contact: contact, entered_at: Time.current) }

    def foreign_card(stage: second_stage)
      other = Contact.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com")
      other_contact_inbox = ContactInbox.create!(inbox: inbox, contact: other, source_id: SecureRandom.hex(4))
      other_conversation = Conversation.create!(inbox: inbox, contact: other, contact_inbox: other_contact_inbox)
      Message.create!(conversation: other_conversation, inbox: inbox, message_type: :incoming,
                      content: 'hello', sender: other)
      pipeline.pipeline_items.create!(pipeline_stage: stage, conversation: other_conversation,
                                      custom_fields: { 'services' => [{ 'name' => 'Setup', 'value' => '10' }] })
    end

    def count_queries(&)
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      queries
    end

    def count_loaded(klass, &)
      records = 0
      counter = ->(*, payload) { records += payload[:record_count] if payload[:class_name] == klass.name }
      ActiveSupport::Notifications.subscribed(counter, 'instantiation.active_record', &)
      records
    end

    it 'runs the same number of queries for by_contact whatever the number of cards' do
      2.times { foreign_card }
      small = count_queries { get "/api/v1/pipelines/by_contact/#{contact.id}" }
      expect(response).to have_http_status(:success)

      6.times { foreign_card }
      large = count_queries { get "/api/v1/pipelines/by_contact/#{contact.id}" }

      expect(large).to eq(small)
    end

    it 'runs the same number of queries for by_conversation whatever the number of cards' do
      2.times { foreign_card }
      small = count_queries { get "/api/v1/pipelines/by_conversation/#{conversation.id}" }
      expect(response).to have_http_status(:success)

      6.times { foreign_card }
      large = count_queries { get "/api/v1/pipelines/by_conversation/#{conversation.id}" }

      expect(large).to eq(small)
    end

    it 'loads only the cards of the contact and of the conversation' do
      8.times { foreign_card }

      expect(count_loaded(PipelineItem) { get "/api/v1/pipelines/by_contact/#{contact.id}" }).to eq(2)
      expect(count_loaded(PipelineItem) { get "/api/v1/pipelines/by_conversation/#{conversation.id}" }).to eq(1)
    end

    it 'keeps the counters of the whole pipeline on each stage' do
      3.times { foreign_card }

      get "/api/v1/pipelines/by_contact/#{contact.id}"

      body = response.parsed_body['data'].sole
      stages = body['stages'].index_by { |s| s['name'] }
      expect(body['item_count']).to eq(5)
      expect(stages['New']).to include('item_count' => 2, 'total_value' => 0.0)
      expect(stages['Won']).to include('item_count' => 3, 'total_value' => 30.0, 'items' => [])
    end

    it 'answers the contact\'s cards with tasks, unread count and latest message' do
      foreign_card

      get "/api/v1/pipelines/by_contact/#{contact.id}"

      items = response.parsed_body['data'].sole['stages'].flat_map { |s| s['items'] }.index_by { |i| i['id'] }
      expect(items.keys).to contain_exactly(conversation_item.id, lead_item.id)
      expect(items.values).to all(include('tasks_info'))
      expect(items[conversation_item.id]['conversation']).to include('unread_count' => 1)
      expect(items[conversation_item.id]['conversation']['last_non_activity_message']).to include('content' => 'hi')
      expect(items[lead_item.id]['contact']).to include('id' => contact.id)
    end

    it 'answers only the conversation\'s card on by_conversation' do
      foreign_card

      get "/api/v1/pipelines/by_conversation/#{conversation.id}"

      items = response.parsed_body['data'].sole['stages'].flat_map { |s| s['items'] }
      expect(items.pluck('id')).to eq([conversation_item.id])
    end
  end
end
