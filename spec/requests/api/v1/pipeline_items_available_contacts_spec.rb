# frozen_string_literal: true

require 'rails_helper'

# available_contacts served a fixed slice of 50 and ignored page/per_page, so an
# integration holding more contacts than that had no way to walk past the first slice.
RSpec.describe 'Api::V1::PipelineItems available_contacts pagination', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
  end

  after { Current.reset }

  def get_available_contacts(params = {})
    get "/api/v1/pipelines/#{pipeline.id}/pipeline_items/available_contacts", params: params
    response.parsed_body
  end

  describe 'with more contacts than one page holds' do
    let!(:contacts) do
      Array.new(7) do |i|
        Contact.create!(name: format('Contact %02d', i), email: "c-#{i}-#{SecureRandom.hex(4)}@example.com")
      end
    end

    it 'walks through the pages instead of repeating the first slice' do
      first_page = get_available_contacts(page: 1, per_page: 3)
      expect(response).to have_http_status(:success)
      first_ids = first_page['data'].pluck('id')
      expect(first_ids.size).to eq(3)

      second_page = get_available_contacts(page: 2, per_page: 3)
      second_ids = second_page['data'].pluck('id')

      expect(second_ids.size).to eq(3)
      expect(second_ids & first_ids).to be_empty
    end

    it 'reports the totals so a caller knows when to stop' do
      body = get_available_contacts(page: 1, per_page: 3)
      pagination = body['meta']['pagination']

      expect(pagination['page']).to eq(1)
      expect(pagination['page_size']).to eq(3)
      expect(pagination['total']).to eq(contacts.size)
      expect(pagination['total_pages']).to eq(3)
      expect(pagination['has_next_page']).to be(true)
      expect(pagination['has_previous_page']).to be(false)
    end

    it 'covers every contact across the pages, without duplicates' do
      seen = (1..3).flat_map { |page| get_available_contacts(page: page, per_page: 3)['data'].pluck('id') }

      expect(seen).to match_array(contacts.map(&:id))
    end

    it 'keeps the search filter working page by page' do
      body = get_available_contacts(search: 'Contact 0', page: 1, per_page: 2)

      expect(body['data'].size).to eq(2)
      expect(body['meta']['pagination']['total']).to eq(7)
    end
  end

  describe 'with contacts sharing a name' do
    let!(:contacts) do
      Array.new(30) { |i| Contact.create!(name: 'Same Name', email: "same-#{i}-#{SecureRandom.hex(4)}@example.com") }
    end

    it 'still pages without duplicates or gaps' do
      seen = (1..5).flat_map { |page| get_available_contacts(page: page, per_page: 7)['data'].pluck('id') }

      expect(seen).to match_array(contacts.map(&:id))
    end
  end

  describe 'page size' do
    let!(:contacts) do
      Array.new(3) do |i|
        Contact.create!(name: "Sized #{i}", email: "s-#{i}-#{SecureRandom.hex(4)}@example.com")
      end
    end

    # The add-item modal calls this endpoint with no pagination params at all, and it
    # used to receive up to 50 contacts. That default has to survive.
    it 'defaults to 50 per page when the caller asks for nothing' do
      body = get_available_contacts

      expect(body['data'].size).to eq(contacts.size)
      expect(body['meta']['pagination']['page']).to eq(1)
      expect(body['meta']['pagination']['page_size']).to eq(50)
    end

    it 'caps an oversized page so one call cannot ask for the whole table' do
      body = get_available_contacts(per_page: 5000)

      expect(body['meta']['pagination']['page_size']).to eq(100)
    end

    it 'falls back to the default when the page is zero or negative' do
      body = get_available_contacts(page: 0)

      expect(body['meta']['pagination']['page']).to eq(1)
      expect(body['data'].size).to eq(contacts.size)
    end
  end

  it 'excludes contacts already holding a card in this pipeline' do
    inside = Contact.create!(name: 'Already in', email: "in-#{SecureRandom.hex(4)}@example.com")
    outside = Contact.create!(name: 'Still out', email: "out-#{SecureRandom.hex(4)}@example.com")
    pipeline.pipeline_items.create!(pipeline_stage: stage, contact: inside, entered_at: Time.current)

    ids = get_available_contacts['data'].pluck('id')

    expect(ids).to include(outside.id)
    expect(ids).not_to include(inside.id)
  end
end
