# frozen_string_literal: true

module Templates
  # Strips secrets from attribute hashes during export and zeroes URL-bearing
  # fields during import (SSRF defense).
  #
  # Allow-list approach: each category declares which fields are safe to export;
  # unknown fields are dropped silently. Secrets discovered later cannot leak
  # because they were never copied in.
  class Sanitizer
    # Fields whose values are forcibly nilled on import even if present in the
    # bundle. Format: { 'category' => %w[field1 field2] }
    URL_FIELDS_BLOCKED_ON_IMPORT = {
      'agents' => %w[outgoing_url api_key],
      'inboxes' => %w[hmac_token website_token]
    }.freeze

    # JSONB keys to scrub inside Channel::Whatsapp.provider_config on export.
    WHATSAPP_PROVIDER_CONFIG_SECRETS = %w[
      api_key
      waba_id
      webhook_verify_token
      access_token
      phone_number_id
    ].freeze

    # JSONB keys to scrub inside Channel::Email.provider_config on export.
    EMAIL_PROVIDER_CONFIG_SECRETS = %w[
      access_token
      refresh_token
      expires_at
      client_id
      client_secret
    ].freeze

    # Sanitize a Macro.actions array: send_webhook_event has a URL we must drop.
    def self.scrub_macro_actions(actions)
      return [] unless actions.is_a?(Array)

      actions.map do |action|
        next action unless action.is_a?(Hash)

        if action['action_name'].to_s == 'send_webhook_event'
          action.merge('action_params' => nil)
        else
          action
        end
      end
    end

    # Sanitize Channel::Whatsapp.provider_config jsonb.
    def self.scrub_whatsapp_provider_config(config)
      return {} unless config.is_a?(Hash)

      config.except(*WHATSAPP_PROVIDER_CONFIG_SECRETS)
    end

    # Sanitize Channel::Email.provider_config jsonb.
    def self.scrub_email_provider_config(config)
      return {} unless config.is_a?(Hash)

      config.except(*EMAIL_PROVIDER_CONFIG_SECRETS)
    end

    # Defense in depth: on import, blank out any URL-bearing field that survived
    # somehow. Called per category by CategoryImporters::Base.
    def self.zero_blocked_fields!(category, attributes)
      blocked = URL_FIELDS_BLOCKED_ON_IMPORT[category.to_s] || []
      blocked.each { |field| attributes[field] = nil if attributes.key?(field) }
      attributes
    end
  end
end
