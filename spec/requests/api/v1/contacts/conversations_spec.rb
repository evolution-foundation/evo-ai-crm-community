# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Contacts::Conversations', type: :request do
  let(:user) { User.create!(name: 'Conversation Probe', email: "conv-probe-#{SecureRandom.hex(4)}@example.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://contact-conv.example.com') }
  let(:inbox) { Inbox.create!(name: 'Contact Conversations Inbox', channel: channel) }
  let(:contact) do
    Contact.create!(name: 'Maria', phone_number: '+5511999887766', identifier: '5511999887766@s.whatsapp.net')
  end
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:read_all) { true }

  before do
    probe = user
    can_read_all = read_all
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
      Current.evo_can_read_all_inboxes = can_read_all
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
  end

  after { Current.reset }

  def create_conversation(identifier: nil, in_inbox: nil)
    target = in_inbox || inbox
    ci = if target == inbox
           contact_inbox
         else
           ContactInbox.create!(contact: contact, inbox: target, source_id: SecureRandom.hex(8))
         end
    conversation = Conversation.create!(inbox: target, contact: contact, contact_inbox: ci,
                                        identifier: identifier)
    Message.create!(conversation: conversation, inbox: target, message_type: :incoming,
                    content: "oi #{conversation.id}", sender: contact)
    conversation
  end

  def other_inbox(name)
    channel = Channel::WebWidget.create!(website_url: "https://#{name}-#{SecureRandom.hex(3)}.example.com")
    Inbox.create!(name: name, channel: channel)
  end

  def count_queries
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get "/api/v1/contacts/#{contact.id}/conversations", as: :json
    end
    queries
  end

  def json_response
    response.parsed_body
  end

  it 'answers the list in the standard envelope' do
    conversation = create_conversation

    get "/api/v1/contacts/#{contact.id}/conversations", as: :json

    expect(response).to have_http_status(:ok)
    expect(json_response['success']).to be(true)
    expect(json_response['data'].map { |c| c['id'] }).to contain_exactly(conversation.id)
  end

  it 'exposes the conversation identifier and the contact reconciliation fields' do
    create_conversation(identifier: 'ext-thread-42')

    get "/api/v1/contacts/#{contact.id}/conversations", as: :json

    item = json_response['data'].first
    expect(item['identifier']).to eq('ext-thread-42')
    expect(item['contact']).to include(
      'id' => contact.id,
      'identifier' => '5511999887766@s.whatsapp.net',
      'phone_number' => '+5511999887766'
    )
  end

  it 'fills unread count and last message from the batch lookups' do
    conversation = create_conversation
    last_message = conversation.messages.where.not(message_type: :activity).reorder(created_at: :desc, id: :desc).first

    get "/api/v1/contacts/#{contact.id}/conversations", as: :json

    item = json_response['data'].first
    expect(item['unread_count']).to eq(1)
    expect(item['last_non_activity_message']['id']).to eq(last_message.id)
  end

  it 'keeps the query count flat as the contact gains conversations' do
    create_conversation

    baseline = count_queries
    3.times { create_conversation }

    expect(count_queries).to eq(baseline)
  end

  it 'keeps the query count flat when the conversations sit in different inboxes' do
    create_conversation(in_inbox: other_inbox('first'))

    baseline = count_queries
    3.times { |i| create_conversation(in_inbox: other_inbox("spread-#{i}")) }

    expect(count_queries).to eq(baseline)
  end

  it 'resolves the label chips instead of answering an empty list' do
    label = Label.create!(title: 'urgente', color: '#ff0000')
    create_conversation.update!(label_list: ['urgente'])

    get "/api/v1/contacts/#{contact.id}/conversations", as: :json

    expect(json_response['data'].first['labels']).to contain_exactly(
      hash_including('id' => label.id, 'title' => 'urgente', 'color' => '#ff0000')
    )
  end

  it 'pages the list and reports how many conversations there are' do
    stub_const('Api::V1::Contacts::ConversationsController::CONVERSATIONS_PER_PAGE', 2)
    3.times { create_conversation }

    get "/api/v1/contacts/#{contact.id}/conversations", as: :json

    expect(json_response['data'].size).to eq(2)
    expect(json_response['meta']).to include(
      'total_count' => 3, 'current_page' => 1, 'per_page' => 2,
      'total_pages' => 2, 'has_next_page' => true, 'has_previous_page' => false
    )

    get "/api/v1/contacts/#{contact.id}/conversations?page=2", as: :json

    expect(json_response['data'].size).to eq(1)
    expect(json_response['meta']).to include('current_page' => 2, 'has_next_page' => false)
  end

  context 'when the caller cannot read conversations' do
    it 'answers 403 instead of the list' do
      create_conversation
      allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(false)

      get "/api/v1/contacts/#{contact.id}/conversations", as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  context 'when the account masks contact PII' do
    before do
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
    end

    it 'masks the embedded contact identifier and phone' do
      create_conversation

      get "/api/v1/contacts/#{contact.id}/conversations", as: :json

      embedded = json_response['data'].first['contact']
      expect(embedded['identifier']).not_to include('5511999887766')
      expect(embedded['identifier']).to end_with('@s.whatsapp.net')
      expect(embedded['phone_number']).not_to eq('+5511999887766')
    end
  end

  context 'when the user cannot read the conversation inbox' do
    let(:read_all) { false }

    it 'leaves the conversation out' do
      create_conversation

      get "/api/v1/contacts/#{contact.id}/conversations", as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to eq([])
    end
  end
end
