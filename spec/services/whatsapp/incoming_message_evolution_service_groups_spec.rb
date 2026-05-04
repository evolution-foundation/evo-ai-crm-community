# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageEvolutionService do
  let(:provider_service) { instance_double(Whatsapp::Providers::EvolutionService) }
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution', provider_service: provider_service) }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:contact) do
    instance_double(Contact, id: 99, name: 'WhatsApp Group 99876', identifier: '12345-9876@g.us', update!: true).tap do |c|
      allow(c).to receive(:name).and_return('WhatsApp Group 99876')
    end
  end
  let(:contact_inbox) { instance_double(ContactInbox, id: 7, contact: contact, source_id: '12345-9876@g.us') }
  let(:builder) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox) }

  let(:service) { described_class.new(inbox: inbox, params: { event: 'messages.upsert', data: {} }) }

  let(:group_message_payload) do
    {
      key: { id: 'msg-1', remoteJid: '12345-9876@g.us', fromMe: false, participant: '5511999999999@s.whatsapp.net' },
      pushName: 'Alice',
      messageTimestamp: 1_700_000_000,
      message: { conversation: 'hi everyone' }
    }
  end

  let(:individual_message_payload) do
    {
      key: { id: 'msg-2', remoteJid: '5511888888888@s.whatsapp.net', fromMe: false },
      pushName: 'Bob',
      messageTimestamp: 1_700_000_001,
      message: { conversation: 'hey' }
    }
  end

  before do
    service.instance_variable_set(:@inbox, inbox)
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
    allow(provider_service).to receive(:fetch_group_subject).and_return(nil)
  end

  describe '#message_processable?' do
    before do
      allow(service).to receive_messages(ignore_message?: false, find_message_by_source_id: false, message_under_process?: false)
    end

    it 'allows group JIDs (the previous filter dropped them silently)' do
      service.instance_variable_set(:@raw_message, group_message_payload)
      expect(service.send(:message_processable?)).to be true
    end

    it 'still allows user JIDs (regression guard for 1:1 chats)' do
      service.instance_variable_set(:@raw_message, individual_message_payload)
      expect(service.send(:message_processable?)).to be true
    end

    it 'still rejects unsupported JID types like newsletter' do
      service.instance_variable_set(:@raw_message, { key: { id: 'msg-x', remoteJid: '123@newsletter' } })
      expect(service.send(:message_processable?)).to be false
    end
  end

  describe '#set_contact (group branch)' do
    before { service.instance_variable_set(:@raw_message, group_message_payload) }

    it 'creates the contact keyed by the group JID, not by any participant' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:source_id]).to eq('12345-9876@g.us')
        expect(args[:inbox]).to eq(inbox)
        builder
      end
      service.send(:set_contact)
    end

    it 'sets contact identifier to the group JID and name to the fallback group subject' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(
          identifier: '12345-9876@g.us',
          name: a_string_matching(/WhatsApp Group/)
        )
        builder
      end
      service.send(:set_contact)
    end

    it 'does not assign phone_number to the group contact (would fail Contact format validation)' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).not_to have_key(:phone_number)
        builder
      end
      service.send(:set_contact)
    end
  end

  describe '#conversation_params (group branch)' do
    before do
      service.instance_variable_set(:@contact, contact)
      service.instance_variable_set(:@contact_inbox, contact_inbox)
    end

    it 'tags additional_attributes.evolution_chat_id with the group JID' do
      service.instance_variable_set(:@raw_message, group_message_payload)
      params = service.send(:conversation_params)
      expect(params[:additional_attributes]).to eq(evolution_chat_id: '12345-9876@g.us')
    end

    it 'omits additional_attributes for individual conversations (regression guard)' do
      service.instance_variable_set(:@raw_message, individual_message_payload)
      params = service.send(:conversation_params)
      expect(params).not_to have_key(:additional_attributes)
    end
  end

  describe '#message_content_attributes (sender_name for groups)' do
    it 'attaches the participant push name as sender_name for group messages' do
      service.instance_variable_set(:@raw_message, group_message_payload)
      attrs = service.send(:message_content_attributes)
      expect(attrs[:sender_name]).to eq('Alice')
    end

    it 'does not attach sender_name for individual messages (regression guard)' do
      service.instance_variable_set(:@raw_message, individual_message_payload)
      attrs = service.send(:message_content_attributes)
      expect(attrs).not_to have_key(:sender_name)
    end

    it 'tags media_type when the message carries a media attachment' do
      payload = group_message_payload.deep_dup
      payload[:message] = { imageMessage: { caption: 'pic', mimetype: 'image/jpeg' } }
      service.instance_variable_set(:@raw_message, payload)
      attrs = service.send(:message_content_attributes)
      expect(attrs[:media_type]).to eq('image')
      expect(attrs[:sender_name]).to eq('Alice')
    end
  end

  describe 'group subject resolution via REST' do
    before { service.instance_variable_set(:@raw_message, group_message_payload) }

    it 'uses the real subject from provider_service.fetch_group_subject when available' do
      allow(provider_service).to receive(:fetch_group_subject).with('12345-9876@g.us').and_return('Time Comercial')

      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes][:name]).to eq('Time Comercial')
        builder
      end
      service.send(:set_contact)
    end

    it 'falls back to the synthetic label when the REST lookup returns nil' do
      allow(provider_service).to receive(:fetch_group_subject).and_return(nil)

      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes][:name]).to match(/\AWhatsApp Group/)
        builder
      end
      service.send(:set_contact)
    end

    it 'survives when provider_service does not expose fetch_group_subject' do
      allow(channel).to receive(:provider_service).and_return(Object.new)

      expect { service.send(:set_contact) }.not_to raise_error
    end
  end

  describe '#update_group_name_if_safe (regression: never overwrite operator rename)' do
    before do
      service.instance_variable_set(:@raw_message, group_message_payload)
      service.instance_variable_set(:@contact, contact)
      service.instance_variable_set(:@contact_inbox, contact_inbox)
    end

    it 'updates the name when current is the synthetic fallback and the new subject is real' do
      allow(contact).to receive(:name).and_return('WhatsApp Group 12349876')
      expect(contact).to receive(:update!).with(name: 'Time Comercial')
      service.send(:update_group_name_if_safe, 'Time Comercial')
    end

    it 'does NOT overwrite an operator-renamed group with the synthetic fallback' do
      allow(contact).to receive(:name).and_return('Renomeado pelo operador')
      expect(contact).not_to receive(:update!)
      service.send(:update_group_name_if_safe, 'WhatsApp Group 9876')
    end

    it 'does NOT overwrite an operator-renamed group with a real subject either' do
      allow(contact).to receive(:name).and_return('Renomeado pelo operador')
      expect(contact).not_to receive(:update!)
      service.send(:update_group_name_if_safe, 'Time Comercial')
    end

    it 'is a no-op when subject is blank' do
      expect(contact).not_to receive(:update!)
      service.send(:update_group_name_if_safe, nil)
    end
  end
end
