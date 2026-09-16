# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox, type: :model do
  let(:api_channel) { Channel::Api.create! }
  let(:whatsapp_channel) do
    Channel::Whatsapp.new(
      phone_number: '+5511999998888',
      provider: 'whatsapp_cloud',
      provider_config: {}
    ).tap { |whatsapp| whatsapp.save(validate: false) }
  end

  describe '#archive!' do
    it 'sets archived_at and disconnects the channel provider when supported' do
      inbox = Inbox.create!(name: 'WhatsApp Inbox', channel: whatsapp_channel)

      expect(whatsapp_channel).to receive(:disconnect_channel_provider)

      inbox.archive!

      expect(inbox.reload.archived_at).to be_present
      expect(inbox.archived?).to be true
    end

    # Regression (C1): Channel::Whatsapp defines #disconnect_channel_provider
    # unconditionally, so respond_to? is always true, but the underlying
    # provider_service only implements it for Evolution/Evolution Go. For every
    # other provider the call raises NoMethodError. Deliberately NOT stubbed —
    # stubbing the channel is exactly what masked this bug in the test above.
    it 'still archives when the provider does not implement disconnect_channel_provider' do
      inbox = Inbox.create!(name: 'Cloud Inbox', channel: whatsapp_channel)

      expect(whatsapp_channel.provider_service).not_to respond_to(:disconnect_channel_provider)
      expect { inbox.archive! }.not_to raise_error

      expect(inbox.reload.archived_at).to be_present
      expect(inbox.archived?).to be true
    end

    it 'does not raise for a channel type with no disconnect_channel_provider method' do
      inbox = Inbox.create!(name: 'API Inbox', channel: api_channel)

      expect { inbox.archive! }.not_to raise_error
      expect(inbox.reload.archived_at).to be_present
    end
  end

  describe '#reactivate!' do
    it 'clears archived_at' do
      inbox = Inbox.create!(name: 'Test Inbox', channel: api_channel)
      inbox.update!(archived_at: Time.current)

      inbox.reactivate!

      expect(inbox.reload.archived_at).to be_nil
    end
  end

  describe '#archived?' do
    it 'is true only when archived_at is present' do
      inbox = Inbox.new(name: 'Test Inbox', channel: api_channel, archived_at: nil)
      expect(inbox.archived?).to be false

      inbox.archived_at = Time.current
      expect(inbox.archived?).to be true
    end
  end
end
