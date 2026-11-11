# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::EvolutionGoBotMentionMatcher do
  subject(:matcher) { described_class.new(channel) }

  let(:channel) do
    instance_double(Channel::Whatsapp, id: 'channel-1', phone_number: '+5571991589983',
                                       provider_config: { 'api_url' => 'https://evogo.example/', 'instance_token' => 'tok' })
  end
  let(:user_info_body) do
    { 'data' => { 'Users' => { '5571991589983@s.whatsapp.net' => { 'LID' => '123456789012345@lid' } } } }
  end
  let(:lid_response) { instance_double(HTTParty::Response, success?: true, parsed_response: user_info_body) }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(HTTParty).to receive(:post).and_return(lid_response)
  end

  it 'matches a mention by phone JID' do
    expect(matcher.mentioned?(['5571991589983@s.whatsapp.net'])).to be(true)
  end

  it 'matches a phone JID carrying a device suffix' do
    expect(matcher.mentioned?(['5571991589983:12@s.whatsapp.net'])).to be(true)
  end

  it 'matches the Brazilian JID without the ninth digit' do
    expect(matcher.mentioned?(['557191589983@s.whatsapp.net'])).to be(true)
  end

  it 'matches the Brazilian JID with the ninth digit when the inbox number lacks it' do
    allow(channel).to receive(:phone_number).and_return('+557191589983')

    expect(matcher.mentioned?(['5571991589983@s.whatsapp.net'])).to be(true)
  end

  it 'does not match a mention of someone else' do
    expect(matcher.mentioned?(['5511999990000@s.whatsapp.net'])).to be(false)
  end

  it 'does not match when there are no mentions' do
    expect(matcher.mentioned?([])).to be(false)
    expect(HTTParty).not_to have_received(:post)
  end

  it 'matches a LID mention resolved through the Evolution Go user info' do
    expect(matcher.mentioned?(['123456789012345@lid'])).to be(true)
    expect(HTTParty).to have_received(:post).with(
      'https://evogo.example/user/info',
      hash_including(headers: hash_including('apikey' => 'tok'), body: { number: %w[5571991589983 557191589983] }.to_json)
    )
  end

  it 'caches the LID lookup across calls' do
    2.times { matcher.mentioned?(['123456789012345@lid']) }
    described_class.new(channel).mentioned?(['999@lid'])

    expect(HTTParty).to have_received(:post).once
  end

  it 'does not match another LID' do
    expect(matcher.mentioned?(['999999999999999@lid'])).to be(false)
  end

  it 'falls back to phone-only matching when the LID lookup fails' do
    allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout)

    expect(matcher.mentioned?(['123456789012345@lid'])).to be(false)
    expect(matcher.mentioned?(['5571991589983@s.whatsapp.net'])).to be(true)
  end

  it 'caches a failed LID lookup for a short while instead of retrying on every message' do
    allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout)

    3.times { described_class.new(channel).mentioned?(['123456789012345@lid']) }

    expect(HTTParty).to have_received(:post).once
  end

  it 'scopes the cached LID to the inbox number' do
    matcher.mentioned?(['123456789012345@lid'])
    allow(channel).to receive(:phone_number).and_return('+5511988887777')

    described_class.new(channel).mentioned?(['123456789012345@lid'])

    expect(HTTParty).to have_received(:post).twice
  end

  it 'does not invent a ninth-digit variant for a landline' do
    allow(channel).to receive(:phone_number).and_return('+557133334444')

    expect(matcher.mentioned?(['5571933334444@s.whatsapp.net'])).to be(false)
    expect(matcher.mentioned?(['557133334444@s.whatsapp.net'])).to be(true)
  end
end
