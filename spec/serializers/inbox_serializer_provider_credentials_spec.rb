# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe InboxSerializer do
  describe 'WhatsApp provider credentials' do
    # Every secret value starts with "secret-", so a leak anywhere in the payload
    # shows up in the JSON whatever key carries it.
    provider_configs = {
      'default' => {
        stored: { 'api_key' => 'secret-360dialog-key' },
        kept: {}
      },
      'whatsapp_cloud' => {
        stored: {
          'api_key' => 'secret-meta-access-token',
          'webhook_verify_token' => 'secret-verify-token',
          'phone_number_id' => '1098',
          'business_account_id' => '7654',
          'evolution_hub' => {
            'channel_id' => 'hub-channel-1',
            'channel_token' => 'secret-hub-channel-token',
            'status' => 'active',
            'public_link' => 'https://hub.test/connect/abc'
          }
        },
        kept: {
          'phone_number_id' => '1098',
          'business_account_id' => '7654',
          'evolution_hub' => {
            'channel_id' => 'hub-channel-1',
            'status' => 'active',
            'public_link' => 'https://hub.test/connect/abc'
          }
        }
      },
      'evolution' => {
        stored: {
          'api_url' => 'https://evolution.test',
          'admin_token' => 'secret-evolution-admin',
          'instance_name' => 'loja-centro',
          'mark_as_read' => false
        },
        kept: { 'api_url' => 'https://evolution.test', 'instance_name' => 'loja-centro', 'mark_as_read' => false }
      },
      'evolution_go' => {
        stored: {
          'api_url' => 'https://evolution-go.test',
          'admin_token' => 'secret-evolution-go-admin',
          'instance_token' => 'secret-evolution-go-instance',
          'instance_uuid' => 'b7f0c0de-0000-4000-8000-000000000001'
        },
        kept: { 'api_url' => 'https://evolution-go.test', 'instance_uuid' => 'b7f0c0de-0000-4000-8000-000000000001' }
      },
      'notificame' => {
        stored: { 'api_token' => 'secret-notificame-token', 'channel_id' => 'nm-channel-9' },
        kept: { 'channel_id' => 'nm-channel-9' }
      },
      'zapi' => {
        stored: {
          'instance_id' => 'zapi-instance-3',
          'token' => 'secret-zapi-token',
          'client_token' => 'secret-zapi-client-token'
        },
        kept: { 'instance_id' => 'zapi-instance-3' }
      }
    }

    let(:user) { User.create!(name: 'Leitor', email: "leitor-#{SecureRandom.hex(4)}@example.com") }

    before do
      stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    end

    after { Current.reset }

    def whatsapp_inbox(provider, config)
      channel = Channel::Whatsapp.new(
        phone_number: "+55119#{rand(10**8).to_s.rjust(8, '0')}",
        provider: provider,
        provider_config: config,
        provider_connection: {}
      ).tap { |c| c.save!(validate: false) }
      Inbox.create!(channel: channel, name: "WA #{provider}")
    end

    def act_as(user, can_edit:)
      Current.user = user
      allow(user).to receive(:has_permission?).and_return(false)
      allow(user).to receive(:has_permission?).with('inboxes.update').and_return(can_edit)
    end

    provider_configs.each do |provider, configs|
      context "with the #{provider} provider" do
        let(:inbox) { whatsapp_inbox(provider, configs[:stored]) }

        it 'leaves the credentials out for a user who can only read the channel' do
          act_as(user, can_edit: false)

          result = described_class.serialize(inbox, include_channel: true)

          expect(result['provider_config']).to eq(configs[:kept])
          expect(result.dig('channel', 'provider_config')).to eq(configs[:kept])
          expect(result.to_json).not_to include('secret-')
        end

        it 'hands the whole provider_config to a user who can edit the channel' do
          act_as(user, can_edit: true)

          result = described_class.serialize(inbox, include_channel: true)

          expect(result['provider_config']).to eq(configs[:stored])
          expect(result.dig('channel', 'provider_config')).to eq(configs[:stored])
        end

        it 'hands the whole provider_config to a service token' do
          Current.service_authenticated = true

          expect(described_class.serialize(inbox)['provider_config']).to eq(configs[:stored])
        end

        it 'leaves the credentials out when nobody is identified' do
          expect(described_class.serialize(inbox).to_json).not_to include('secret-')
        end
      end
    end
  end

  describe 'channel secrets in the full channel hash' do
    before do
      stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
      Current.service_authenticated = true
    end

    after { Current.reset }

    def channel_hash(channel, name)
      channel.save!(validate: false)
      described_class.serialize(Inbox.create!(channel: channel, name: name), include_channel: true)['channel']
    end

    it 'leaves the Twilio auth token and API key SID out' do
      data = channel_hash(Channel::TwilioSms.new(account_sid: 'AC123', auth_token: 'secret-twilio-auth',
                                                 api_key_sid: 'secret-twilio-key-sid', phone_number: '+5511955554444'),
                          'Twilio')

      expect(data['account_sid']).to eq('AC123')
      expect(data.to_json).not_to include('secret-')
    end

    it 'leaves the Telegram bot token out' do
      channel = Channel::Telegram.new(bot_token: 'secret-telegram-bot', bot_name: 'loja_bot')
      allow(channel).to receive(:setup_telegram_webhook).and_return(true)

      data = channel_hash(channel, 'Telegram')

      expect(data['bot_name']).to eq('loja_bot')
      expect(data.to_json).not_to include('secret-')
    end

    it 'leaves the e-mail passwords and the OAuth tokens out' do
      data = channel_hash(Channel::Email.new(email: "loja-#{SecureRandom.hex(4)}@example.com", forward_to_email: '[EMAIL_REDACTED]',
                                             imap_password: 'secret-imap', smtp_password: 'secret-smtp',
                                             provider_config: { 'access_token' => 'secret-oauth', 'refresh_token' => 'secret-refresh' }),
                          'Email')

      expect(data['forward_to_email']).to eq('[EMAIL_REDACTED]')
      expect(data.to_json).not_to include('secret-')
    end

    it 'leaves the SMS provider credentials out' do
      data = channel_hash(Channel::Sms.new(phone_number: '+5511944443333',
                                           provider_config: { 'api_key' => 'secret-sms-key', 'api_secret' => 'secret-sms-secret' }),
                          'SMS')

      expect(data['phone_number']).to eq('+5511944443333')
      expect(data.to_json).not_to include('secret-')
    end

    it 'sends the WhatsApp connection through the QR code rule' do
      Current.reset
      user = User.create!(name: 'Agente', email: "agente-#{SecureRandom.hex(4)}@example.com")
      Current.user = user
      allow(user).to receive(:has_permission?).and_return(false)
      channel = Channel::Whatsapp.new(phone_number: '+5511933332222', provider: 'evolution',
                                      provider_config: { 'instance_name' => 'loja' },
                                      provider_connection: { 'connection' => 'close', 'qr_data_url' => 'data:image/png;base64,secret-qr' })

      data = channel_hash(channel, 'WA QR')

      expect(data['provider_connection'].stringify_keys).to eq('connection' => 'close')
      expect(data.to_json).not_to include('secret-')
    end
  end
end
