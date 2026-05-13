# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Serializes AgentBot configuration.
    #
    # Drops secrets: api_key, outgoing_url.
    # bot_config jsonb is exported as-is (it's free-form per provider; users
    # should review before sharing). If a known sensitive key is detected at
    # the top level, it's dropped.
    #
    # Custom Tools and Custom MCPs are NOT exported in v1 — they live in
    # evo-ai-core-service-community (external HTTP service), not in this DB.
    # See Phase A1 finding in the tech-spec.
    class AgentsSerializer < Base
      ALLOW_LIST = %w[
        name
        description
        bot_provider
        bot_type
        debounce_time
        delay_per_character
        text_segmentation_enabled
        text_segmentation_limit
        text_segmentation_min_size
        message_signature
      ].freeze
      SLUG_FIELD = :name

      BOT_CONFIG_SENSITIVE_KEYS = %w[api_key token secret access_token refresh_token password].freeze

      def to_h
        base = super
        base['bot_config'] = scrub_bot_config(@record.bot_config)
        base
      end

      private

      def scrub_bot_config(config)
        return {} unless config.is_a?(Hash)

        config.reject { |k, _| BOT_CONFIG_SENSITIVE_KEYS.include?(k.to_s.downcase) }
      end
    end
  end
end
