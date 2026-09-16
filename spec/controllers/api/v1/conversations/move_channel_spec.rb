# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe Api::V1::ConversationsController do
    it 'has controller spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

# Task 9 — PATCH/POST /api/v1/.../conversations/:id/move_channel exposes the
# "Change channel" action (Conversation#eligible_move_target?, Task 8) to
# manually move a conversation to a different inbox. Covers happy path (200),
# ineligible-target rejection (422), missing-inbox (404), and the RBAC gate
# inherited via require_permissions — mirroring return_to_bot_spec.rb's style.
#
# The controller-flow scenarios below use instance_double mocks, matching the
# sibling spec's convention. That convention can't express DB-level behavior
# (moved_from_inbox_id persistence across multiple moves, ContactInboxBuilder
# actually creating a ContactInbox row), so a separate "persisted behavior"
# describe block below runs the same action against real ActiveRecord objects
# for those specific assertions, following the pattern already used in
# spec/models/concerns/conversation_channel_move_spec.rb.
RSpec.describe Api::V1::ConversationsController, type: :controller do
  describe '#move_channel' do
    let(:user) { instance_double(User, role: 'agent') }
    let(:conversation) { instance_double(Conversation) }
    let(:target_inbox) { instance_double(Inbox, id: 99) }
    let(:serialized_payload) { { 'id' => 42, 'inbox_id' => 99 } }

    before do
      allow(Current).to receive(:user).and_return(user)
      allow(controller).to receive(:conversation).and_return(true) # before_action no-op
      controller.instance_variable_set(:@conversation, conversation)
      allow(controller).to receive(:check_move_channel_permission!).and_return(true)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(inbox_id: '99'))
      allow(Inbox).to receive(:find).with('99').and_return(target_inbox)
      allow(ConversationSerializer).to receive(:serialize)
        .with(conversation, include_messages: false)
        .and_return(serialized_payload)
    end

    context 'when the target inbox is an eligible move target' do
      before do
        allow(conversation).to receive(:eligible_move_target?).with(target_inbox).and_return(true)
        allow(conversation).to receive(:inbox_id).and_return(1)
        allow(conversation).to receive(:moved_from_inbox_id).and_return(nil)
        allow(conversation).to receive(:moved_from_inbox_id=)
        allow(conversation).to receive(:update!)
        allow(conversation).to receive(:contact).and_return(instance_double(Contact))
        allow(ContactInboxBuilder).to receive(:new).and_return(instance_double(ContactInboxBuilder, perform: true))
      end

      it 'moves the conversation and responds with the serialized payload' do
        expect(controller).to receive(:success_response).with(
          hash_including(data: serialized_payload, message: 'Conversation moved successfully')
        )
        controller.send(:move_channel)
      end

      it 'updates the conversation inbox_id to the target inbox' do
        allow(controller).to receive(:success_response)
        expect(conversation).to receive(:update!).with(inbox_id: 99)
        controller.send(:move_channel)
      end

      it 'invokes ContactInboxBuilder for the contact and the target inbox' do
        allow(controller).to receive(:success_response)
        contact = instance_double(Contact)
        allow(conversation).to receive(:contact).and_return(contact)
        expect(ContactInboxBuilder).to receive(:new)
          .with(contact: contact, inbox: target_inbox)
          .and_return(instance_double(ContactInboxBuilder, perform: true))
        controller.send(:move_channel)
      end
    end

    context 'when the target inbox is not an eligible move target' do
      before do
        allow(conversation).to receive(:eligible_move_target?).with(target_inbox).and_return(false)
      end

      it 'responds with 422 and does not touch the conversation' do
        expect(conversation).not_to receive(:update!)
        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::VALIDATION_ERROR,
          'Conversation cannot be moved to this channel',
          status: :unprocessable_entity
        )
        controller.send(:move_channel)
      end
    end

    context 'when the target inbox does not exist' do
      before do
        allow(Inbox).to receive(:find).with('99').and_raise(ActiveRecord::RecordNotFound)
      end

      it 'responds with 404' do
        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::RESOURCE_NOT_FOUND, 'Target inbox not found', status: :not_found
        )
        controller.send(:move_channel)
      end
    end
  end

  describe '#move_channel persisted behavior (real ActiveRecord)' do
    # Real objects (not doubles) so we can assert on actual DB state — the
    # instance_double flow above can't verify moved_from_inbox_id persistence
    # or that ContactInboxBuilder really created a ContactInbox row.
    def build_whatsapp_channel(phone_number: "+55119#{SecureRandom.hex(4)}")
      Channel::Whatsapp.create!(
        phone_number: phone_number,
        provider: 'whatsapp_cloud',
        provider_config: { 'api_key' => '', 'phone_number_id' => '', 'evolution_hub' => { 'status' => 'active' } }
      )
    end

    def build_inbox(channel)
      Inbox.create!(name: "Inbox #{SecureRandom.hex(4)}", channel: channel)
    end

    def build_contact(phone_number:)
      Contact.create!(name: 'Test Contact', phone_number: phone_number)
    end

    def build_conversation(inbox:, contact:)
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.random_number(10**10).to_s)
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    end

    before do
      # Current.user is deliberately left real (not stubbed) here: building the
      # real Conversation records below runs through Conversation's creation
      # callbacks (ActionCableListener broadcast), which touch Current.user —
      # an instance_double would fail strict verification against that
      # unrelated call path. move_channel itself never reads Current.user
      # directly, so this is safe; the permission gate is bypassed below.
      allow(controller).to receive(:conversation).and_return(true) # before_action no-op
      allow(controller).to receive(:check_move_channel_permission!).and_return(true)
      allow(ConversationSerializer).to receive(:serialize).and_return({})
    end

    it 'sets inbox_id, records moved_from_inbox_id, and creates a ContactInbox for the target' do
      inbox_a = build_inbox(build_whatsapp_channel)
      inbox_b = build_inbox(build_whatsapp_channel)
      contact = build_contact(phone_number: '+5511999999999')
      conversation = build_conversation(inbox: inbox_a, contact: contact)

      controller.instance_variable_set(:@conversation, conversation)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(inbox_id: inbox_b.id))
      allow(controller).to receive(:success_response)

      controller.send(:move_channel)

      conversation.reload
      expect(conversation.inbox_id).to eq(inbox_b.id)
      expect(conversation.moved_from_inbox_id).to eq(inbox_a.id)
      expect(ContactInbox.exists?(contact_id: contact.id, inbox_id: inbox_b.id)).to be true
    end

    it 'keeps the original moved_from_inbox_id on a second move' do
      inbox_a = build_inbox(build_whatsapp_channel)
      inbox_b = build_inbox(build_whatsapp_channel)
      inbox_c = build_inbox(build_whatsapp_channel)
      contact = build_contact(phone_number: '+5511999999999')
      conversation = build_conversation(inbox: inbox_a, contact: contact)
      conversation.update!(inbox: inbox_b, moved_from_inbox_id: inbox_a.id)

      controller.instance_variable_set(:@conversation, conversation)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(inbox_id: inbox_c.id))
      allow(controller).to receive(:success_response)

      controller.send(:move_channel)

      conversation.reload
      expect(conversation.inbox_id).to eq(inbox_c.id)
      expect(conversation.moved_from_inbox_id).to eq(inbox_a.id)
    end

    it 'rejects a move to an archived inbox with 422 and leaves the conversation unchanged' do
      inbox_a = build_inbox(build_whatsapp_channel)
      inbox_b = build_inbox(build_whatsapp_channel)
      inbox_b.update!(archived_at: Time.current)
      contact = build_contact(phone_number: '+5511999999999')
      conversation = build_conversation(inbox: inbox_a, contact: contact)

      controller.instance_variable_set(:@conversation, conversation)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(inbox_id: inbox_b.id))

      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::VALIDATION_ERROR,
        'Conversation cannot be moved to this channel',
        status: :unprocessable_entity
      )
      controller.send(:move_channel)

      expect(conversation.reload.inbox_id).to eq(inbox_a.id)
    end
  end

  describe 'permission gate wiring' do
    # EvoPermissionConcern#require_permissions defines `check_<action>_permission!`
    # via define_method (see app/controllers/concerns/evo_permission_concern.rb).
    # If the action is missing from the require_permissions mapping, the method
    # is absent — this spec fails the moment the gate is removed.
    it 'installs check_move_channel_permission! via require_permissions' do
      expect(described_class.instance_methods).to include(:check_move_channel_permission!)
    end

    it 'invokes check_permission! with the conversations.update key' do
      controller_instance = described_class.new
      expect(controller_instance).to receive(:check_permission!).with('conversations.update', :user)
      controller_instance.send(:check_move_channel_permission!)
    end
  end
end
