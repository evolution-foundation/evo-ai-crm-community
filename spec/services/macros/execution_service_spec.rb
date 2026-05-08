# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Macros::ExecutionService do
  let(:macro)        { instance_double(Macro, id: 'macro-123') }
  let(:webhook_data) { { conversation: { id: 42 } } }
  let(:conversation) { instance_double(Conversation, webhook_data: webhook_data) }
  let(:user)         { instance_double(User, id: 'user-1') }

  before do
    allow(conversation).to receive(:reload).and_return(conversation)
  end

  describe '#send_webhook_event' do
    let(:service) { described_class.new(macro, conversation, user) }

    it 'enqueues WebhookJob with the stripped URL and macro.executed payload' do
      expect(WebhookJob).to receive(:perform_later).with(
        'https://webhook.site/abc',
        hash_including(event: 'macro.executed')
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
