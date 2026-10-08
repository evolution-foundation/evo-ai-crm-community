# frozen_string_literal: true

require 'rails_helper'

# The settings modal can only point at the field that failed when each detail names
# its field and carries a code it can translate.
RSpec.describe 'Canned response validation errors', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def detail_for(field)
    response.parsed_body.dig('error', 'details').find { |detail| detail['field'] == field }
  end

  it 'names the short_code field when the code is already taken on create' do
    CannedResponse.create!(short_code: 'saudacao', content: 'Olá, tudo bem?')

    post '/api/v1/canned_responses',
         params: { canned_response: { short_code: 'saudacao', content: 'Outra saudação' } },
         headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(detail_for('short_code')).to include('codes' => ['taken'], 'full_messages' => be_present)
  end

  it 'names the short_code field when an update collides with another response' do
    CannedResponse.create!(short_code: 'saudacao', content: 'Olá, tudo bem?')
    other = CannedResponse.create!(short_code: 'despedida', content: 'Até logo!')

    patch "/api/v1/canned_responses/#{other.id}",
          params: { canned_response: { short_code: 'saudacao' } },
          headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(detail_for('short_code')).to include('codes' => ['taken'])
  end
end
