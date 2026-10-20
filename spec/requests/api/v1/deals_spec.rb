# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Deals API', type: :request do
  let(:user) { User.create!(name: 'Deal Owner', email: "deal-owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1) }

  before do
    current_user = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = current_user
      Current.service_authenticated = true
      Current.authentication_method = 'service_token'
    end
  end

  after { Current.reset }

  it 'creates an autonomous deal and exposes compatibility aliases' do
    post "/api/v1/pipelines/#{pipeline.id}/deals", params: {
      deal: { title: 'Annual contract', value: 15_000, currency: 'BRL', pipeline_stage_id: stage.id }
    }, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('data', 'title')).to eq('Annual contract')
    expect(response.parsed_body.dig('data', 'deal_id')).to eq(response.parsed_body.dig('data', 'id'))
    expect(PipelineItem.last.contacts).to be_empty

    get "/api/v1/pipelines/#{pipeline.id}", as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'deal_count')).to eq(1)
    expect(response.parsed_body.dig('data', 'stages', 0, 'deals', 0, 'title')).to eq('Annual contract')
  end

  it 'attaches a conversation and automatically links its contact' do
    contact = Contact.create!(name: 'Customer', email: "customer-#{SecureRandom.hex(3)}@example.com")
    channel = Channel::WebWidget.create!(website_url: "https://#{SecureRandom.hex(3)}.example.com")
    inbox = Inbox.create!(name: 'Inbox', channel: channel)
    contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage)

    post "/api/v1/deals/#{deal.id}/conversations", params: { conversation_id: conversation.id }, as: :json

    expect(response).to have_http_status(:created)
    expect(deal.reload.conversations).to contain_exactly(conversation)
    expect(deal.contacts).to contain_exactly(contact)
    expect(deal.primary_contact).to eq(contact)
  end

  it 'records commercial changes in the append-only timeline' do
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Before')

    patch "/api/v1/deals/#{deal.id}", params: { deal: { title: 'After', notes: 'Qualified' } }, as: :json

    expect(response).to have_http_status(:ok)
    event = deal.reload.deal_history_events.order(:created_at).last
    expect(event.action).to eq('deal_updated')
    expect(event.change_set.dig('title', 'previous')).to eq('Before')
    expect(event.change_set.dig('title', 'current')).to eq('After')
    expect { event.update!(source: 'tampered') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'stores labels on the deal instead of borrowing contact labels' do
    label = Label.create!(title: "priority-#{SecureRandom.hex(3)}", color: '#7c3aed')
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Tagged deal')

    patch "/api/v1/deals/#{deal.id}", params: { deal: { labels: [label.id] } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'labels')).to contain_exactly(
      include('id' => label.id, 'name' => label.title, 'color' => '#7c3aed')
    )
    expect(deal.reload.label_list).to contain_exactly(label.title)
    expect(deal.deal_history_events.pluck(:action)).to include('deal_labels_updated')
  end

  it 'retains its immutable audit records after deleting the deal' do
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Disposable deal')
    deal_id = deal.id

    delete "/api/v1/deals/#{deal_id}", as: :json

    expect(response).to have_http_status(:ok)
    expect(PipelineItem.where(id: deal_id)).not_to exist
    expect(DealHistoryEvent.where(pipeline_item_id: deal_id).pluck(:action)).to include('deal_created', 'deal_deleted')
  end

  it 'uploads and removes a safe deal file while auditing both actions' do
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Documents')
    upload = Rack::Test::UploadedFile.new(StringIO.new('proposal'), 'text/plain', original_filename: 'proposal.txt')

    post "/api/v1/deals/#{deal.id}/files", params: { files: [upload] }

    expect(response).to have_http_status(:created)
    attachment_id = response.parsed_body.dig('data', 0, 'id')
    expect(attachment_id).to be_present
    expect(deal.reload.deal_history_events.pluck(:action)).to include('files_attached')

    delete "/api/v1/deals/#{deal.id}/files/#{attachment_id}"

    expect(response).to have_http_status(:ok)
    expect(deal.reload.attachments).to be_empty
    expect(deal.deal_history_events.pluck(:action)).to include('file_removed')
  end

  it 'rolls back the whole file batch when a later attachment fails' do
    deal = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, title: 'Atomic files')
    files = %w[first second].map do |name|
      Rack::Test::UploadedFile.new(StringIO.new(name), 'text/plain', original_filename: "#{name}.txt")
    end
    saves = 0
    allow_any_instance_of(Attachment).to receive(:save!).and_wrap_original do |original, *args|
      saves += 1
      raise ActiveRecord::RecordInvalid if saves == 2

      original.call(*args)
    end

    post "/api/v1/deals/#{deal.id}/files", params: { files: files }

    expect(response).to have_http_status(:internal_server_error)
    expect(deal.reload.attachments).to be_empty
    expect(deal.deal_history_events.pluck(:action)).not_to include('files_attached')
  end
end
