# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PATCH /api/v1/inboxes/:id avatar validation', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) do
    {
      'X-Service-Token' => service_token
    }
  end
  let(:web_widget_channel) { Channel::WebWidget.create!(website_url: 'https://example.test') }
  let(:inbox) { Inbox.create!(channel: web_widget_channel, name: 'Widget Inbox') }
  let(:invalid_avatar) do
    Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/invalid_avatar.txt'),
      'text/plain'
    )
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  it 'returns validation error details when avatar upload fails' do
    patch "/api/v1/inboxes/#{inbox.id}",
          params: { avatar: invalid_avatar },
          headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_response['success']).to be(false)
    expect(json_response.dig('error', 'code')).to eq('VALIDATION_ERROR')

    avatar_error = json_response.dig('error', 'details')&.find { |detail| detail['field'] == 'avatar' }
    expect(avatar_error).not_to be_nil
    expect(avatar_error['messages']).to include('filetype not supported')
  end
end
