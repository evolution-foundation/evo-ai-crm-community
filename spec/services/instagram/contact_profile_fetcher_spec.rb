# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::ContactProfileFetcher do
  let(:channel) { instance_double(Channel::Instagram, access_token: 'direct-token', evolution_hub_meta: {}) }
  let(:inbox) { instance_double(Inbox, channel: channel) }
  let(:response) { instance_double(HTTParty::Response) }

  it 'fetches the sender-scoped profile_pic directly from the Instagram Graph API' do
    allow(MetaBaseUrl).to receive(:enabled?).and_return(false)
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_API_VERSION', 'v23.0').and_return('v23.0')
    expect(HTTParty).to receive(:get).with(
      'https://graph.instagram.com/v23.0/contact-1?fields=id,name,username,profile_pic&access_token=direct-token',
      open_timeout: 5,
      read_timeout: 10
    ).and_return(response)

    expect(described_class.new(inbox: inbox).call('contact-1')).to eq(response)
  end

  it 'uses the EvoHub proxy and channel token in Hub mode' do
    hub_channel = instance_double(
      Channel::Instagram,
      evolution_hub_meta: { 'channel_token' => 'hub-token' }
    )
    hub_inbox = instance_double(Inbox, channel: hub_channel)
    allow(MetaBaseUrl).to receive(:enabled?).and_return(true)
    allow(MetaBaseUrl).to receive(:for).with(:instagram).and_return('https://hub.example/meta')
    expect(HTTParty).to receive(:get).with(
      'https://hub.example/meta/contact-1?fields=id,name,username,profile_pic',
      headers: { 'Authorization' => 'Bearer hub-token' },
      open_timeout: 5,
      read_timeout: 10
    ).and_return(response)

    expect(described_class.new(inbox: hub_inbox).call('contact-1')).to eq(response)
  end
end
