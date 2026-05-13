# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::Trigger do
  let(:url)     { 'https://example.test/hook' }
  let(:payload) { { event: 'macro.executed', conversation: { id: 42 } } }

  before do
    allow(RestClient::Request).to receive(:execute).and_raise(RestClient::Exceptions::ReadTimeout)
  end

  describe '.execute (webhook type behaviour)' do
    it 're-raises for :macro_webhook so Sidekiq surfaces the failure' do
      expect do
        described_class.execute(url, payload, :macro_webhook)
      end.to raise_error(RestClient::Exceptions::ReadTimeout)
    end

    it 'swallows for :api_inbox_webhook (legacy contract preserved)' do
      expect do
        described_class.execute(url, payload, :api_inbox_webhook)
      end.not_to raise_error
    end

    it 'swallows for :account_webhook (legacy contract preserved)' do
      expect do
        described_class.execute(url, payload, :account_webhook)
      end.not_to raise_error
    end

    it 'swallows for :inbox_webhook (legacy contract preserved)' do
      expect do
        described_class.execute(url, payload, :inbox_webhook)
      end.not_to raise_error
    end

    it 'swallows for :agent_bot (legacy contract preserved)' do
      expect do
        described_class.execute(url, payload, :agent_bot)
      end.not_to raise_error
    end
  end

  describe '.execute (log format)' do
    it 'keeps the legacy "Exception: Invalid webhook URL" prefix for grep compatibility' do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)

      described_class.execute(url, payload, :account_webhook)

      expect(logger).to have_received(:warn).with(/Exception: Invalid webhook URL/)
    end

    it 'redacts query string from the logged URL' do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)
      sensitive_url = 'https://example.test/hook?token=secret123&other=foo'

      described_class.execute(sensitive_url, payload, :account_webhook)

      expect(logger).to have_received(:warn).with(satisfy { |msg|
        msg.include?('https://example.test/hook') && msg.exclude?('token=secret123')
      })
    end

    it 'falls back to <unparseable> for malformed URLs without crashing' do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)

      expect do
        described_class.execute('not a url at all', payload, :account_webhook)
      end.not_to raise_error

      expect(logger).to have_received(:warn).with(/Exception: Invalid webhook URL/)
    end

    it 'includes structured context (type, event, error class) after the legacy prefix' do
      logger = instance_double(Logger, warn: nil)
      allow(Rails).to receive(:logger).and_return(logger)

      begin
        described_class.execute(url, payload, :macro_webhook)
      rescue RestClient::Exceptions::ReadTimeout
        # expected — macro_webhook re-raises
      end

      expect(logger).to have_received(:warn).with(satisfy { |msg|
        msg.include?('type=macro_webhook') &&
          msg.include?('event=macro.executed') &&
          msg.include?('error=RestClient::Exceptions::ReadTimeout')
      })
    end
  end
end
