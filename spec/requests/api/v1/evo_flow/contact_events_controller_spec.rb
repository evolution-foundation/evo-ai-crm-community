require 'rails_helper'

RSpec.describe Api::V1::EvoFlow::ContactEventsController, type: :request do
  describe 'GET /api/v1/contacts/:contact_id/events' do
    let(:contact_id) { SecureRandom.uuid }
    let(:path) { "/api/v1/contacts/#{contact_id}/events" }
    
    before do
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!).and_return(true)

      client_mock = instance_double(EvoFlow::Client)
      allow(EvoFlow::Client).to receive(:new).and_return(client_mock)
      allow(client_mock).to receive(:get).and_return(
        'data' => {
          'events' => [
            {
              'id' => '123',
              'properties' => { 'campaign_id' => 'camp-1' }
            }
          ]
        }
      )
    end

    it 'Business Rule: gracefully handles missing campaigns table in Community Edition without throwing 500' do
      allow(Campaign).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid.new("PG::UndefinedTable: ERROR: relation \"campaigns\" does not exist"))

      get path

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['data']['events'].first['enriched']).to be_nil
    end
  end
end
