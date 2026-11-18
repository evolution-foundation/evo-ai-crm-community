# frozen_string_literal: true

class Ai::ModelResolver
  OPENROUTER_PROVIDER_PREFIX = 'openrouter/'
  OPENROUTER_DEFAULT_MODEL_PROVIDER = 'openai/'

  def self.resolve(model, provider:, openrouter_model: nil)
    return model unless provider == 'openrouter'

    normalized = openrouter_model.presence || model.to_s.strip
    normalized = normalized.delete_prefix(OPENROUTER_PROVIDER_PREFIX)
    return "#{OPENROUTER_DEFAULT_MODEL_PROVIDER}#{normalized}" if normalized.present? && !normalized.include?('/')

    normalized
  end
end
