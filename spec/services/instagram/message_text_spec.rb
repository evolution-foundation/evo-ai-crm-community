# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::MessageText do
  let(:channel) { instance_double(Channel::Instagram) }
  let(:inbox) { instance_double(Inbox, id: 'inbox-1', channel: channel) }
  let(:fetcher) { instance_double(Instagram::ContactProfileFetcher, hub?: false) }
  let(:service) { described_class.new({}, channel) }

  before do
    service.instance_variable_set(:@inbox, inbox)
    allow(Instagram::ContactProfileFetcher).to receive(:new).with(inbox: inbox).and_return(fetcher)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
  end

  it 'normalizes profile_pic returned by the shared profile fetcher' do
    response = instance_double(
      HTTParty::Response,
      success?: true,
      code: 200,
      body: { id: 'ig-1', name: 'Contact', username: 'contact', profile_pic: 'https://cdn.example/a.jpg' }.to_json
    )
    allow(fetcher).to receive(:call).with('ig-1').and_return(response)

    result = service.fetch_instagram_user('ig-1')

    expect(result).to include(
      'id' => 'ig-1',
      'profile_pic' => 'https://cdn.example/a.jpg',
      'profile_picture_url' => 'https://cdn.example/a.jpg'
    )
  end

  it 'marks the channel for reauthorization when Meta returns error 190' do
    error = { 'error' => { 'code' => 190, 'message' => 'expired token' } }
    response = instance_double(
      HTTParty::Response,
      success?: false,
      code: 400,
      body: error.to_json,
      parsed_response: error
    )
    allow(fetcher).to receive(:call).with('ig-1').and_return(response)
    allow(Rails.logger).to receive(:error)
    expect(channel).to receive(:authorization_error!)
    allow(EvolutionExceptionTracker).to receive(:new)
      .and_return(instance_double(EvolutionExceptionTracker, capture_exception: nil))

    expect(service.fetch_instagram_user('ig-1')).to eq({})
  end
end
