# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/widget/config', type: :request do
  let(:web_widget_channel) { Channel::WebWidget.create!(website_url: 'https://example.test', locale: channel_locale) }
  let!(:inbox) { Inbox.create!(channel: web_widget_channel, name: 'Widget Inbox') }
  let(:channel_locale) { nil }

  def json_response
    JSON.parse(response.body)
  end

  it 'returns channel locale when configured on widget channel' do
    web_widget_channel.update!(locale: 'pt_BR')

    post '/api/v1/widget/config', params: { website_token: web_widget_channel.website_token }

    expect(response).to have_http_status(:ok)
    expect(json_response.dig('website_channel_config', 'locale')).to eq('pt_BR')
  end

  it 'returns no locale when the widget channel has none, even with DEFAULT_LOCALE set' do
    previous = ENV.fetch('DEFAULT_LOCALE', nil)
    ENV['DEFAULT_LOCALE'] = 'pt_BR'

    post '/api/v1/widget/config', params: { website_token: web_widget_channel.website_token }

    expect(response).to have_http_status(:ok)
    expect(json_response.dig('website_channel_config', 'locale')).to be_nil
  ensure
    previous.nil? ? ENV.delete('DEFAULT_LOCALE') : ENV['DEFAULT_LOCALE'] = previous
  end
end
