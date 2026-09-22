# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageEvolutionGoService do
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'evolution_go') }
  let(:inbox) { instance_double(Inbox, id: 1, channel: channel) }
  let(:contact) { instance_double(Contact, id: 99, name: 'My Squad', identifier: '12345-9876@g.us', update!: true, group?: true) }
  let(:contact_inbox) { instance_double(ContactInbox, id: 7, contact: contact, source_id: '12345-9876@g.us') }
  let(:builder) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox) }

  let(:service) { described_class.new(inbox: inbox, params: { event: 'Message', data: {} }) }

  let(:group_info) do
    {
      ID: 'msg-1',
      Chat: '12345-9876@g.us',
      Sender: '5511999999999@s.whatsapp.net',
      IsFromMe: false,
      IsGroup: true,
      PushName: 'Alice',
      Type: 'conversation',
      Timestamp: '2026-01-15T10:00:00Z'
    }
  end

  let(:individual_info) do
    {
      ID: 'msg-2',
      Chat: '5511888888888@s.whatsapp.net',
      Sender: '5511888888888@s.whatsapp.net',
      IsFromMe: false,
      IsGroup: false,
      PushName: 'Bob',
      Type: 'conversation',
      Timestamp: '2026-01-15T10:00:01Z'
    }
  end

  let(:group_data) do
    { groupData: { Name: 'My Squad', Subject: 'My Squad' } }
  end

  before do
    service.instance_variable_set(:@inbox, inbox)
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
  end

  describe '#set_contact (group branch)' do
    before do
      service.instance_variable_set(:@evolution_go_info, group_info)
      service.instance_variable_set(:@evolution_go_data, group_data)
    end

    it 'creates a contact keyed by the group JID (Chat), not by the participant Sender' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:source_id]).to eq('12345-9876@g.us')
        builder
      end
      service.send(:set_contact)
    end

    it 'uses the group subject from groupData as the contact name when present' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(name: 'My Squad', identifier: '12345-9876@g.us')
        builder
      end
      service.send(:set_contact)
    end

    it 'falls back to a deterministic group name when groupData is missing' do
      service.instance_variable_set(:@evolution_go_data, {})
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes][:name]).to match(/WhatsApp Group/)
        builder
      end
      service.send(:set_contact)
    end

    it 'does not assign phone_number to a group contact' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).not_to have_key(:phone_number)
        builder
      end
      service.send(:set_contact)
    end

    it 'does not enqueue a profile picture fetch for groups (would fail with non-phone identifier)' do
      expect(service).not_to receive(:update_contact_profile_picture)
      service.send(:set_contact)
    end
  end

  describe '#set_contact (individual branch — regression guard)' do
    before do
      service.instance_variable_set(:@evolution_go_info, individual_info)
      service.instance_variable_set(:@evolution_go_data, {})
      allow(service).to receive_messages(update_contact_profile_picture: nil, update_contact_information: nil)
    end

    it 'still routes to the individual contact builder for non-group messages' do
      expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
        expect(args[:contact_attributes]).to include(:phone_number)
        builder
      end
      service.send(:set_contact)
    end
  end

  describe '#set_contact (individual branch — LID/phone dedup regression)' do
    let(:phone_source_id) { '5511888888888' }
    let(:lid_source_id) { '5511888888888@lid' }

    let(:existing_contact) { instance_double(Contact, id: 55, name: 'Carol', identifier: nil, update!: true, group?: false) }
    let(:existing_contact_inbox) do
      instance_double(ContactInbox, id: 20, contact_id: 55, contact: existing_contact, source_id: phone_source_id,
                                     update!: true)
    end
    let(:contact_inboxes_relation) { instance_double(ActiveRecord::Relation) }

    before do
      allow(inbox).to receive(:contact_inboxes).and_return(contact_inboxes_relation)
      allow(service).to receive_messages(update_contact_profile_picture: nil, update_contact_information: nil)
    end

    context 'when the contact was previously created via the bare phone source_id and a later event arrives as @lid' do
      let(:lid_info) { individual_info.merge(Chat: '5511888888888@lid', Sender: '5511888888888@lid') }

      before do
        service.instance_variable_set(:@evolution_go_info, lid_info)
        service.instance_variable_set(:@evolution_go_data, {})
        allow(contact_inboxes_relation).to receive(:where)
          .with(source_id: array_including(phone_source_id, lid_source_id))
          .and_return([existing_contact_inbox])
      end

      it 'reuses the existing ContactInbox instead of creating a second Contact/Conversation' do
        expect(ContactInboxWithContactBuilder).not_to receive(:new)
        expect(existing_contact_inbox).to receive(:update!).with(source_id: lid_source_id)

        service.send(:set_contact)

        expect(service.instance_variable_get(:@contact)).to eq(existing_contact)
        expect(service.instance_variable_get(:@contact_inbox)).to eq(existing_contact_inbox)
      end
    end

    context 'when no existing ContactInbox matches either the phone or @lid form' do
      before do
        service.instance_variable_set(:@evolution_go_info, individual_info)
        service.instance_variable_set(:@evolution_go_data, {})
        allow(contact_inboxes_relation).to receive(:where).and_return([])
      end

      it 'falls through to creating a new contact as before (no regression on the happy path)' do
        expect(ContactInboxWithContactBuilder).to receive(:new) do |args|
          expect(args[:source_id]).to eq(phone_source_id)
          builder
        end
        service.send(:set_contact)
      end
    end
  end

  describe '#message_content_attributes' do
    it 'includes the participant pushName as sender_name for group messages' do
      service.instance_variable_set(:@evolution_go_info, group_info)
      attrs = service.send(:message_content_attributes)
      expect(attrs[:sender_name]).to eq('Alice')
    end

    it 'omits sender_name for individual messages (regression guard)' do
      service.instance_variable_set(:@evolution_go_info, individual_info)
      attrs = service.send(:message_content_attributes)
      expect(attrs).not_to have_key(:sender_name)
    end

    it 'tags media_type from Info.MediaType for media messages' do
      service.instance_variable_set(:@evolution_go_info, group_info.merge(MediaType: 'video'))
      attrs = service.send(:message_content_attributes)
      expect(attrs[:media_type]).to eq('video')
    end
  end

  describe '#update_group_name_if_safe (regression: never overwrite operator rename)' do
    before do
      service.instance_variable_set(:@evolution_go_info, group_info)
      service.instance_variable_set(:@evolution_go_data, group_data)
      service.instance_variable_set(:@contact, contact)
      service.instance_variable_set(:@contact_inbox, contact_inbox)
    end

    it 'updates the name when current is the synthetic fallback and the new subject is real' do
      allow(contact).to receive(:name).and_return('WhatsApp Group 12349876')
      expect(contact).to receive(:update!).with(name: 'My Squad')
      service.send(:update_group_name_if_safe)
    end

    it 'does NOT overwrite an operator-renamed group with the synthetic fallback' do
      service.instance_variable_set(:@evolution_go_data, {})
      allow(contact).to receive(:name).and_return('Renomeado pelo operador')
      expect(contact).not_to receive(:update!)
      service.send(:update_group_name_if_safe)
    end

    it 'does NOT overwrite an operator-renamed group with a real subject either' do
      allow(contact).to receive(:name).and_return('Renomeado pelo operador')
      expect(contact).not_to receive(:update!)
      service.send(:update_group_name_if_safe)
    end
  end

  describe '#set_contact — retrofit pre-existing contact without type=group' do
    let(:pre_existing_contact) do
      instance_double(Contact, id: 42, name: 'My Squad', identifier: '12345-9876@g.us',
                               update!: true, update_columns: true, group?: false)
    end
    let(:contact_inbox_for_pre_existing) { instance_double(ContactInbox, id: 8, contact: pre_existing_contact, source_id: '12345-9876@g.us') }
    let(:builder_for_pre_existing) { instance_double(ContactInboxWithContactBuilder, perform: contact_inbox_for_pre_existing) }

    before do
      service.instance_variable_set(:@evolution_go_info, group_info)
      service.instance_variable_set(:@evolution_go_data, group_data)
      allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder_for_pre_existing)
    end

    it 'calls update_columns(type: group) to retrofit a pre-existing contact that lacks the group type' do
      expect(pre_existing_contact).to receive(:update_columns).with(type: 'group')
      service.send(:set_contact)
    end
  end
end
