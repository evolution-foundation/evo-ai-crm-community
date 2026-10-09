# frozen_string_literal: true

require 'rails_helper'

# The channel list shows each channel's own address next to its name. The address
# is all the inbox payload carries of the channel: its configuration holds credentials.
RSpec.describe InboxSerializer do
  def serialize(channel)
    described_class.serialize(Inbox.new(channel: channel, name: 'canal'))
  end

  Channel::Whatsapp::PROVIDERS.each do |provider|
    it "exposes the phone number of a #{provider} WhatsApp channel" do
      result = serialize(Channel::Whatsapp.new(provider: provider, phone_number: '+5511988887777'))

      expect(result['phone_number']).to eq('+5511988887777')
      expect(result).not_to have_key('email')
    end
  end

  it 'exposes the phone number of an SMS channel, without its configuration' do
    result = serialize(Channel::Sms.new(phone_number: '+5511977776666', provider_config: { 'api_key' => 'secret' }))

    expect(result['phone_number']).to eq('+5511977776666')
    expect(result.to_json).not_to include('secret')
  end

  it 'exposes the phone number of a Twilio channel, without its credentials' do
    result = serialize(Channel::TwilioSms.new(phone_number: '+5511966665555', account_sid: 'AC123', auth_token: 'secret'))

    expect(result['phone_number']).to eq('+5511966665555')
    expect(result.to_json).not_to include('secret')
  end

  it 'exposes the address of an e-mail channel, without its credentials' do
    result = serialize(Channel::Email.new(email: '[EMAIL_REDACTED]', imap_password: 'secret', smtp_password: 'secret'))

    expect(result['email']).to eq('[EMAIL_REDACTED]')
    expect(result).not_to have_key('phone_number')
    expect(result.to_json).not_to include('secret')
  end

  it 'exposes the sender address of a SendGrid channel' do
    result = serialize(Channel::Sendgrid.new(from_email: '[EMAIL_REDACTED]'))

    expect(result['email']).to eq('[EMAIL_REDACTED]')
  end

  [
    -> { Channel::FacebookPage.new(page_id: 'page-1') },
    -> { Channel::Instagram.new(instagram_id: 'ig-1') },
    -> { Channel::Telegram.new(bot_name: 'evo_bot') }
  ].each do |build|
    it "leaves #{build.call.class.name} with no address" do
      result = serialize(build.call)

      expect(result).not_to have_key('phone_number')
      expect(result).not_to have_key('email')
    end
  end
end
