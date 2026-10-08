# frozen_string_literal: true

require 'rails_helper'

# The modal validates these too, but the API is the boundary: a direct call has to be
# refused with the field that failed and a code the client can translate.
RSpec.describe 'Custom attribute definition validation errors', type: :request do
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

  def create_definition(**attrs)
    post '/api/v1/custom_attribute_definitions',
         params: {
           custom_attribute_definition: {
             attribute_display_name: 'Plano',
             attribute_key: 'plano',
             attribute_model: 'contact_attribute',
             attribute_display_type: 'text'
           }.merge(attrs)
         },
         headers: headers, as: :json
  end

  it 'refuses a list without values' do
    create_definition(attribute_display_type: 'list', attribute_values: [])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(detail_for('attribute_values')).to include('codes' => ['blank'])
    expect(CustomAttributeDefinition.exists?(attribute_key: 'plano')).to be(false)
  end

  it 'refuses a regex pattern that does not compile' do
    create_definition(regex_pattern: '([a-z')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(detail_for('regex_pattern')).to include('codes' => ['invalid'])
  end

  it 'answers a reserved key with a code, not with the sentence' do
    create_definition(attribute_key: 'email')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(detail_for('attribute_key')).to include('codes' => ['key_conflict'], 'full_messages' => be_present)
  end

  it 'names the attribute_key field when the key is already taken' do
    create_definition
    expect(response).to have_http_status(:created)

    create_definition(attribute_display_name: 'Outro plano')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(detail_for('attribute_key')).to include('codes' => ['taken'])
  end
end
