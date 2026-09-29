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
    let(:channel) { instance_double(Channel::Whatsapp, id: 1) }
    let(:inbox) { instance_double(Inbox, channel: channel) }
    let(:service) { described_class.new(inbox: inbox, params: { instance: 'vendedor-2' }) }

    before do
      allow(service).to receive(:processed_params).and_return({ instance: 'vendedor-2' })
    end

    it 'marks the channel connected on state=open (clears reauth flag + resets provider_connection)' do
      expect(channel).to receive(:mark_connected!)
      service.send(:handle_connection_open, nil)
    end
  end

  describe 'presence.update event' do
    let(:inbox) { instance_double(Inbox, archived?: false, contact_inboxes: contact_inboxes_relation) }
    let(:contact_inboxes_relation) { instance_double(ActiveRecord::Relation, find_by: contact_inbox) }
    let(:contact_inbox) { instance_double(ContactInbox, conversations: conversations_relation) }
    let(:conversations_relation) { instance_double(ActiveRecord::Relation, where: where_chain) }
    let(:where_chain) { double('WhereChain', not: not_resolved_relation) }
    let(:not_resolved_relation) { instance_double(ActiveRecord::Relation, last: conversation) }
    let(:conversation) { instance_double(Conversation, display_id: 5, contact_id: 'contact-1') }

    def service_for(data)
      described_class.new(inbox: inbox, params: { event: 'presence.update', data: data, instance: 'test' })
    end

    it 'extends the debounce for a composing signal' do
      data = { id: '5511999999999@s.whatsapp.net', presences: { '5511999999999@s.whatsapp.net' => { lastKnownPresence: 'composing' } } }

      expect(BotRuntime::PresenceDelegationService).to receive(:new).with(conversation).and_return(instance_double(BotRuntime::PresenceDelegationService, delegate: true))

      service_for(data).perform
    end

    it 'does nothing for a paused signal' do
      data = { id: '5511999999999@s.whatsapp.net', presences: { '5511999999999@s.whatsapp.net' => { lastKnownPresence: 'paused' } } }

      expect(BotRuntime::PresenceDelegationService).not_to receive(:new)

      service_for(data).perform
    end

    it 'ignores group presence (@g.us)' do
      data = { id: '123456-group@g.us', presences: { 'x@g.us' => { lastKnownPresence: 'composing' } } }

      expect(inbox).not_to receive(:contact_inboxes)

      service_for(data).perform
    end

    it 'discards silently when no ContactInbox matches the sender' do
      allow(contact_inboxes_relation).to receive(:find_by).and_return(nil)
      data = { id: '5511999999999@s.whatsapp.net', presences: { '5511999999999@s.whatsapp.net' => { lastKnownPresence: 'composing' } } }

      expect(BotRuntime::PresenceDelegationService).not_to receive(:new)

      expect { service_for(data).perform }.not_to raise_error
    end

    # Regression: the ContactInbox for a DDD >= 31 mobile is stored with the
    # nono dígito stripped (Whatsapp::PhoneNumberNormalizer.call), but the raw
    # JID always carries it. A presence lookup using the raw digits directly
    # (as this handler did before Whatsapp::PresenceContactResolver) would
    # never match — silently disabling the feature for most Brazilian DDDs.
    it 'resolves the ContactInbox stored under the normalized (nono dígito stripped) source_id' do
      raw_jid_digits = '5574999879409' # DDD 74, raw JID keeps the 9
      normalized_source_id = '557499879409' # stored form, 9 stripped
      data = { id: "#{raw_jid_digits}@s.whatsapp.net", presences: { "#{raw_jid_digits}@s.whatsapp.net" => { lastKnownPresence: 'composing' } } }

      allow(contact_inboxes_relation).to receive(:find_by).with(source_id: raw_jid_digits).and_return(nil)
      allow(contact_inboxes_relation).to receive(:find_by).with(source_id: normalized_source_id).and_return(contact_inbox)

      expect(BotRuntime::PresenceDelegationService).to receive(:new).with(conversation).and_return(instance_double(BotRuntime::PresenceDelegationService, delegate: true))

      service_for(data).perform
    end
  end
end
