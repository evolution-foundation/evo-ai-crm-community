# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::CategorySerializers::InboxesSerializer' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Templates::CategorySerializers::InboxesSerializer do
  describe 'WhatsApp inbox' do
    let(:channel) do
      Channel::Whatsapp.create!(
        phone_number: "+55119#{rand(10_000_000..99_999_999)}",
        provider: 'whatsapp_cloud',
        provider_config: { 'api_key' => 'secret', 'waba_id' => 'W' },
        provider_connection: { 'session' => 'abc' }
      )
    end
    let(:inbox) { Inbox.create!(name: 'Suporte WA', channel: channel, greeting_enabled: true) }
    let(:hash) { described_class.new(inbox).to_h }

    it 'flags requires_credentials: true' do
      expect(hash['requires_credentials']).to be true
    end

    it 'does not leak the phone number' do
      expect(hash.to_json).not_to include(channel.phone_number)
    end

    it 'does not leak provider_config secrets' do
      json = hash.to_json
      expect(json).not_to include('secret')
      expect(json).not_to include('"waba_id"')
    end

    it 'keeps non-sensitive inbox attributes' do
      expect(hash['name']).to eq('Suporte WA')
      expect(hash['greeting_enabled']).to be true
      expect(hash['channel_type']).to eq('Channel::Whatsapp')
      expect(hash['channel_attributes']['provider']).to eq('whatsapp_cloud')
    end
  end
end
