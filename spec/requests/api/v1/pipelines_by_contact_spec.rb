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
end
