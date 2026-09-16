require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Knowledge::EmbeddingService do
  describe '#embed' do
    before do
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :knowledge_embedding)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'sk-test-key', base_url: nil))
    end

    it 'returns the embedding vector from the OpenAI response' do
      stub_request(:post, 'https://api.openai.com/v1/embeddings')
        .with(
          body: hash_including(model: 'text-embedding-3-small', input: 'hello'),
          headers: { 'Authorization' => 'Bearer sk-test-key' }
        )
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { data: [{ embedding: Array.new(1536, 0.01) }] }.to_json
        )

      result = described_class.new.embed('hello')

      expect(result).to be_an(Array)
      expect(result.length).to eq(1536)
    end

    it 'honors a custom base_url from the resolved credential' do
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :knowledge_embedding)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: 'sk-test-key', base_url: 'https://my-proxy.example.com/v1'))

      stub_request(:post, 'https://my-proxy.example.com/v1/embeddings')
        .to_return(status: 200, body: { data: [{ embedding: Array.new(1536, 0.01) }] }.to_json)

      described_class.new.embed('hello')

      expect(a_request(:post, 'https://my-proxy.example.com/v1/embeddings')).to have_been_made
    end

    it 'raises Knowledge::EmbeddingService::Error on a non-2xx response' do
      stub_request(:post, 'https://api.openai.com/v1/embeddings').to_return(status: 500, body: 'boom')

      expect { described_class.new.embed('hello') }.to raise_error(Knowledge::EmbeddingService::Error)
    end

    it 'raises Knowledge::EmbeddingService::Error when no credential is configured' do
      allow(Ai::CredentialResolver).to receive(:resolve_endpoint)
        .with(for_consumer: :knowledge_embedding)
        .and_return(Ai::CredentialResolver::Endpoint.new(key: nil, base_url: nil))

      expect { described_class.new.embed('hello') }.to raise_error(Knowledge::EmbeddingService::Error, /credential/i)
    end
  end
end
