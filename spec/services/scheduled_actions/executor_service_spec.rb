# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledActions::ExecutorService do
  subject(:service) { described_class.new(scheduled_action) }

  let(:scheduled_action) { instance_double(ScheduledAction, contact: contact) }
  let(:contact) { instance_double(Contact, phone_number: '+5511999999999', contact_inboxes: contact_inboxes_relation) }
  let(:contact_inboxes_relation) { instance_double(ActiveRecord::Relation) }
  let(:whatsapp_inbox) { instance_double(Inbox) }
  let(:whatsapp_cloud_inbox) { instance_double(Inbox) }
  let(:sms_inbox) { instance_double(Inbox) }
  let(:telegram_inbox) { instance_double(Inbox, id: 'telegram-inbox') }
  let(:sms_scope) { instance_double(ActiveRecord::Relation, first: sms_inbox) }
  let(:telegram_scope) { instance_double(ActiveRecord::Relation, first: telegram_inbox) }
  let(:telegram_contact_inbox) { instance_double(ContactInbox, source_id: 'telegram-source-id') }

  describe '#channel_config' do
    it 'uses Channel::Whatsapp when available' do
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(whatsapp_inbox)
      expect(Inbox).not_to receive(:find_by).with(channel_type: 'Channel::WhatsappCloud')

      config = service.send(:channel_config, 'whatsapp')

      expect(config[:inbox]).to eq(whatsapp_inbox)
      expect(config[:source_id]).to eq('5511999999999')
    end

    it 'falls back to Channel::WhatsappCloud when Channel::Whatsapp is unavailable' do
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(nil)
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::WhatsappCloud').and_return(whatsapp_cloud_inbox)

      config = service.send(:channel_config, 'whatsapp')

      expect(config[:inbox]).to eq(whatsapp_cloud_inbox)
      expect(config[:source_id]).to eq('5511999999999')
    end

    it 'returns a not configured error when no WhatsApp inbox exists' do
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(nil)
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::WhatsappCloud').and_return(nil)

      config = service.send(:channel_config, 'whatsapp')

      expect(config).to eq(
        success: false,
        error: 'WhatsApp not configured for this account'
      )
    end

    it 'resolves sms channel config with Channel::Sms inbox and phone source id' do
      allow(Inbox).to receive(:where).with(channel_type: 'Channel::Sms').and_return(sms_scope)

      config = service.send(:channel_config, 'sms')

      expect(config[:inbox]).to eq(sms_inbox)
      expect(config[:source_id]).to eq('+5511999999999')
      expect(config[:error_msg]).to eq('SMS not configured')
    end

    it 'resolves telegram channel config with existing contact inbox source id' do
      allow(Inbox).to receive(:where).with(channel_type: 'Channel::Telegram').and_return(telegram_scope)
      allow(contact_inboxes_relation).to receive(:find_by).with(inbox_id: 'telegram-inbox').and_return(telegram_contact_inbox)

      config = service.send(:channel_config, 'telegram')

      expect(config[:inbox]).to eq(telegram_inbox)
      expect(config[:source_id]).to eq('telegram-source-id')
      expect(config[:error_msg]).to eq('Telegram not configured')
    end

    it 'returns an explicit error for unknown channel values' do
      config = service.send(:channel_config, 'unknown')

      expect(config).to eq(
        success: false,
        error: 'Unknown channel: unknown'
      )
    end
  end
end
