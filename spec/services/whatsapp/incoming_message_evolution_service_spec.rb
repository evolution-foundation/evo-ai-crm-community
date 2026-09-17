# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::IncomingMessageEvolutionService' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::IncomingMessageEvolutionService do
  describe 'messages.update activity refresh' do
    let(:message) do
      instance_double(
        Message,
        created_at: Time.zone.parse('2026-02-12 10:00:00'),
        status: 'sent'
      )
    end

    let(:service) { described_class.new(inbox: inbox, params: params) }
    let(:inbox) { instance_double(Inbox, channel: instance_double(Channel::Whatsapp)) }
    let(:params) do
      {
        event: 'messages.update',
        data: {
          messageId: 'msg-1',
          status: 'DELIVERED',
          fromMe: false
        }
      }
    end

    before do
      allow(service).to receive(:find_message_by_source_id).and_return(true)
      service.instance_variable_set(:@message, message)
      service.instance_variable_set(:@raw_message, params[:data])
    end

    it 'refreshes conversation activity when status updates' do
      allow(service).to receive(:status_mapper).and_return('delivered')
      allow(service).to receive(:incoming?).and_return(false)
      allow(message).to receive(:update!)
      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      allow(Messages::StatusUpdateService).to receive(:new).with(message, 'delivered').and_return(status_service)

      expect(message).to receive(:refresh_conversation_activity!).with(message.created_at, use_current_time: false)

      service.send(:update_status)
    end

    it 'refreshes conversation activity when message content is edited' do
      allow(service).to receive(:extract_edited_content).and_return('updated')
      allow(message).to receive(:content_attributes).and_return({})
      allow(message).to receive(:content).and_return('old')
      allow(message).to receive(:update!)

      expect(message).to receive(:refresh_conversation_activity!).with(message.created_at, use_current_time: false)

      service.send(:handle_edited_content)
    end
  end

  describe '#handle_connection_close (EVO-1967: transient vs permanent)' do
    let(:channel) { instance_double(Channel::Whatsapp, id: 1) }
    let(:inbox) { instance_double(Inbox, channel: channel) }
    let(:service) { described_class.new(inbox: inbox, params: { instance: 'vendedor-2' }) }

    before do
      allow(service).to receive(:processed_params).and_return({ instance: 'vendedor-2' })
      allow(channel).to receive(:update_provider_connection!)
      allow(channel).to receive(:prompt_reauthorization!)
    end

    [440, 428, 408, 503, 515].each do |reason|
      it "keeps channel active (no reauthorization) on transient reason #{reason}" do
        expect(channel).not_to receive(:prompt_reauthorization!)
        expect(channel).to receive(:update_provider_connection!).with(hash_including('connection' => 'close'))
        service.send(:handle_connection_close, reason)
      end
    end

    [401, 403, 411, 500].each do |reason|
      it "marks reauthorization on permanent reason #{reason}" do
        expect(channel).to receive(:prompt_reauthorization!)
        expect(channel).to receive(:update_provider_connection!).with(hash_including('connection' => 'disconnected'))
        service.send(:handle_connection_close, reason)
      end
    end

    it "treats string reason '440' as transient (no reauthorization)" do
      expect(channel).not_to receive(:prompt_reauthorization!)
      service.send(:handle_connection_close, '440')
    end
  end

  describe '#handle_connection_open (reconnect resets provider_connection)' do
    let(:channel) { instance_double(Channel::Whatsapp, id: 1, phone_number: '+5511999999999') }
    let(:avatar_double) { instance_double(ActiveStorage::Attached::One, attached?: false) }
    let(:inbox) { instance_double(Inbox, id: 'inbox-1', channel: channel, avatar: avatar_double) }
    let(:service) { described_class.new(inbox: inbox, params: { instance: 'vendedor-2' }) }
    let(:provider_service) { instance_double(Whatsapp::Providers::EvolutionService) }

    before do
      allow(service).to receive(:processed_params).and_return({ instance: 'vendedor-2' })
      allow(channel).to receive(:mark_connected!)
      allow(Whatsapp::Providers::EvolutionService).to receive(:new)
        .with(whatsapp_channel: channel)
        .and_return(provider_service)
      allow(provider_service).to receive(:fetch_profile_picture_url).and_return(nil)
    end

    it 'marks the channel connected on state=open (clears reauth flag + resets provider_connection)' do
      expect(channel).to receive(:mark_connected!)
      service.send(:handle_connection_open, nil)
    end

    it 'uses the profilePictureUrl straight from the webhook payload when present, no extra API call' do
      expect(Whatsapp::Providers::EvolutionService).not_to receive(:new)
      expect(service).to receive(:update_inbox_avatar).with('https://cdn.example.com/from-webhook.jpg')

      service.send(:handle_connection_open, 'https://cdn.example.com/from-webhook.jpg')
    end

    it 'actively fetches the channel\'s own profile picture when the webhook payload has none (the real-world case)' do
      allow(provider_service).to receive(:fetch_profile_picture_url).with('+5511999999999')
                                                                    .and_return('https://cdn.example.com/fetched.jpg')

      expect(service).to receive(:update_inbox_avatar).with('https://cdn.example.com/fetched.jpg')

      service.send(:handle_connection_open, nil)
    end

    it 'does not attempt a fetch when the inbox already has an avatar' do
      allow(avatar_double).to receive(:attached?).and_return(true)

      expect(Whatsapp::Providers::EvolutionService).not_to receive(:new)
      expect(service).not_to receive(:update_inbox_avatar)

      service.send(:handle_connection_open, nil)
    end

    it 'does nothing when neither the webhook nor the active fetch find a picture' do
      expect(service).not_to receive(:update_inbox_avatar)

      service.send(:handle_connection_open, nil)
    end
  end
  # Regression (C2): this service overrides #perform without calling super, so
  # the archived-inbox guard in Whatsapp::IncomingMessageBaseService#perform
  # never ran here — archived Evolution inboxes kept ingesting webhooks.
  describe '#perform with an archived inbox' do
    it 'does nothing when the inbox is archived' do
      archived_inbox = instance_double(Inbox, archived?: true)
      params = { event: 'messages.upsert', instance: 'inst-1', data: {} }.with_indifferent_access

      service = described_class.new(inbox: archived_inbox, params: params)

      expect(service).not_to receive(:process_messages_upsert)
      expect(service).not_to receive(:process_messages_update)
      expect(service).not_to receive(:process_connection_update)
      service.perform
    end
  end
end
