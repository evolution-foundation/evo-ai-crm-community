# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Macros::ExecutionService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:macro) do
    Macro.create!(
      name: 'Test macro',
      created_by: user,
      updated_by: user,
      actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://webhook.site/abc'] }]
    )
  end

  describe '#send_webhook_event' do
    let(:service) { described_class.new(macro, conversation, user) }

    it 'enqueues WebhookJob with the stripped URL, macro.executed payload, and :macro_webhook type' do
      expect(WebhookJob).to receive(:perform_later).with(
        'https://webhook.site/abc',
        hash_including(event: 'macro.executed'),
        :macro_webhook
      )

      service.send(:send_webhook_event, ["  https://webhook.site/abc  \t"])
    end

    it 'skips enqueue and warns when the URL is blank' do
      expect(WebhookJob).not_to receive(:perform_later)
      expect(Rails.logger).to receive(:warn).with(/skipping send_webhook_event/)

      service.send(:send_webhook_event, ['   '])
    end

    it 'skips enqueue when params is nil' do
      expect(WebhookJob).not_to receive(:perform_later)
      service.send(:send_webhook_event, nil)
    end
  end
end
