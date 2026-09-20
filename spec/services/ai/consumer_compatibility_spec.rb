# frozen_string_literal: true

require 'rails_helper'

# Every AI feature is registered here, and the
# resolver reads this map instead of each consumer carrying its own rule.
RSpec.describe Ai::ConsumerCompatibility do
  it 'registers the seven AI features of the CRM' do
    expect(described_class::CONSUMERS.keys).to contain_exactly(
      :ai_agents, :inbox_assist, :audio_transcription, :label_suggestion, :moderation,
      :knowledge_embedding, :memory_compression
    )
  end

  it 'lets AI Agents use every provider' do
    expect(described_class.accepted_providers(:ai_agents)).to eq(described_class::ALL_PROVIDERS)
    expect(described_class.accepts?(:ai_agents, 'anthropic')).to be(true)
    expect(described_class.accepts?(:ai_agents, 'gemini')).to be(true)
  end

  # These four build an OpenAI-shaped request (Whisper for transcription, or
  # the embeddings endpoint) that only a provider speaking that exact protocol
  # can serve. A non-OpenAI-shaped provider there is a different protocol, not
  # a misconfiguration, so it must never reach the wire.
  %i[audio_transcription label_suggestion moderation knowledge_embedding].each do |consumer|
    it "restricts #{consumer} to OpenAI-compatible providers" do
      expect(described_class.accepts?(consumer, 'openai')).to be(true)
      expect(described_class.accepts?(consumer, 'azure')).to be(true)
      expect(described_class.accepts?(consumer, 'custom')).to be(true)
      # OpenRouter exposes OpenAI-shaped /embeddings and /audio/transcriptions
      # endpoints too (verified against its own docs), unlike a bare
      # chat-completions-only provider.
      expect(described_class.accepts?(consumer, 'openrouter')).to be(true)

      expect(described_class.accepts?(consumer, 'anthropic')).to be(false)
      expect(described_class.accepts?(consumer, 'gemini')).to be(false)
      expect(described_class.accepts?(consumer, 'bedrock')).to be(false)
      # groq/deepseek/together_ai/fireworks_ai are unverified for embeddings
      # and transcription — chat-completions-only, so they stay rejected here.
      expect(described_class.accepts?(consumer, 'groq')).to be(false)
    end
  end

  # These two build a chat-completions request via HTTParty (inbox_assist) or
  # Net::HTTP (memory_compression), and neither hardcodes api.openai.com —
  # both already resolve their URL from the credential's own base_url. Any
  # provider that speaks the OpenAI chat-completions wire protocol works here,
  # not just the narrower embeddings/transcription-capable set.
  %i[inbox_assist memory_compression].each do |consumer|
    it "accepts OpenAI-chat-completions-compatible providers for #{consumer}" do
      expect(described_class.accepts?(consumer, 'openai')).to be(true)
      expect(described_class.accepts?(consumer, 'azure')).to be(true)
      expect(described_class.accepts?(consumer, 'custom')).to be(true)
      expect(described_class.accepts?(consumer, 'openrouter')).to be(true)
      expect(described_class.accepts?(consumer, 'groq')).to be(true)
      expect(described_class.accepts?(consumer, 'deepseek')).to be(true)
      expect(described_class.accepts?(consumer, 'together_ai')).to be(true)
      expect(described_class.accepts?(consumer, 'fireworks_ai')).to be(true)

      expect(described_class.accepts?(consumer, 'anthropic')).to be(false)
      expect(described_class.accepts?(consumer, 'gemini')).to be(false)
      expect(described_class.accepts?(consumer, 'bedrock')).to be(false)
    end
  end

  it 'rejects an unknown consumer instead of guessing' do
    expect(described_class.known?(:not_a_feature)).to be(false)
    expect(described_class.accepts?(:not_a_feature, 'openai')).to be(false)
  end

  it 'accepts string or symbol consumers' do
    expect(described_class.known?('inbox_assist')).to be(true)
    expect(described_class.accepts?('inbox_assist', 'openai')).to be(true)
  end
end
