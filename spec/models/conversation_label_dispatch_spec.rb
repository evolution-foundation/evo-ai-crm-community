# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for the conversation_updated dispatch on label changes.
#
# Before this fix, Conversation#create_label_change (invoked from
# after_update_commit -> create_activity -> handle_label_change) explicitly
# dispatched CONVERSATION_UPDATED in addition to the standard
# notify_conversation_updation dispatch in the same callback chain.
#
# The duplicate dispatch caused every label-change listener (AutomationRule,
# Webhook, Hook, etc.) to fire twice per label addition/removal. With
# attribute_changed on labels now working (EVO-1058), the duplicate is no
# longer hidden by a silent crash and would re-execute destructive actions
# like assign_to_pipeline.

RSpec.describe Conversation do
  describe 'label change event dispatch' do
    let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { described_class.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    around do |example|
      Current.user = user
      example.run
    ensure
      Current.reset
    end

    it 'dispatches CONVERSATION_UPDATED exactly once when a label is added by a user' do
      conversation
      dispatch_calls = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, *_args|
        dispatch_calls << event_name
      end

      conversation.update!(label_list: ['atleta'])

      label_dispatches = dispatch_calls.count { |name| name == described_class::CONVERSATION_UPDATED }
      expect(label_dispatches).to be(1)
    end

    it 'dispatches CONVERSATION_UPDATED exactly once when a label is removed by a user' do
      conversation.update!(label_list: ['atleta'])
      dispatch_calls = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, *_args|
        dispatch_calls << event_name
      end

      conversation.update!(label_list: [])

      label_dispatches = dispatch_calls.count { |name| name == described_class::CONVERSATION_UPDATED }
      expect(label_dispatches).to be(1)
    end
  end
end
