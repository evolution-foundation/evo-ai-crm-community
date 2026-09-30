# frozen_string_literal: true

# Which providers each AI feature can actually talk to (FR18).
#
# AI Agents reach every provider through the core service. The others build a
# `POST /chat/completions` call, so a non-OpenAI provider there is not a
# misconfiguration but a different protocol, and it fails at the wire.
#
# New consumers register here; the resolver needs no change.
class Ai::ConsumerCompatibility
  ALL_PROVIDERS = :all

  CONSUMERS = {
    ai_agents: ALL_PROVIDERS,
    inbox_assist: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    # Groq and OpenRouter both expose the OpenAI-compatible audio/transcriptions
    # contract even though the core does not classify them as general chat
    # providers. Keep this allowlist scoped to transcription; accepting them for
    # chat-based CRM helpers would be a separate capability decision.
    audio_transcription: (Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS + %w[groq openrouter]).freeze,
    label_suggestion: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    moderation: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS
  }.freeze

  class << self
    def known?(consumer)
      CONSUMERS.key?(consumer&.to_sym)
    end

    def accepted_providers(consumer)
      CONSUMERS[consumer&.to_sym]
    end

    def accepts?(consumer, provider)
      accepted = accepted_providers(consumer)
      return false if accepted.nil?
      return true if accepted == ALL_PROVIDERS

      accepted.include?(provider)
    end
  end
end
