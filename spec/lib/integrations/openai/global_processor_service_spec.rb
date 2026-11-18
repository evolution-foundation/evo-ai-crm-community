# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::Openai::GlobalProcessorService do
  describe '#credential_endpoint' do
    it 'resolves sentiment analysis through moderation compatibility' do
      service = described_class.new(account: nil, event: { 'name' => 'analyze_sentiment' })
      endpoint = Ai::CredentialResolver::Endpoint.new(key: 'secret', base_url: nil, provider: nil)

      expect(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :moderation).and_return(endpoint)

      expect(service.send(:credential_endpoint)).to eq(endpoint)
    end

    it 'resolves inbox suggestions through Inbox Assist compatibility' do
      service = described_class.new(account: nil, event: { 'name' => 'reply_suggestion' })
      endpoint = Ai::CredentialResolver::Endpoint.new(key: 'secret', base_url: nil, provider: nil)

      expect(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :inbox_assist).and_return(endpoint)

      expect(service.send(:credential_endpoint)).to eq(endpoint)
    end
  end
end
