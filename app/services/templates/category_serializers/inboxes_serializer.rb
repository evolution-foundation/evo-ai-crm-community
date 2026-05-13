# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Serializes Inbox + polymorphic Channel::* with credentials stripped.
    #
    # Each channel type has its own allow-list:
    # - Channel::Api: webhook_url and hmac_mandatory only (no hmac_token, no identifier)
    # - Channel::WebWidget: visual/widget config only (no tokens)
    # - Channel::Whatsapp: provider name only (no phone, no provider_config)
    # - Channel::Email: email-server addresses without credentials, no OAuth tokens
    #
    # Bundle flags `requires_credentials: true` so importer can prefix the inbox
    # name with "[Configurar]" and emit a warning in the report.
    class InboxesSerializer < Base
      ALLOW_LIST = %w[
        name
        channel_type
        greeting_enabled
        greeting_message
        working_hours_enabled
        out_of_office_message
        enable_auto_assignment
        csat_survey_enabled
        csat_config
        allow_messages_after_resolved
        lock_to_single_conversation
        sender_name_type
        default_conversation_status
        timezone
        business_name
      ].freeze
      SLUG_FIELD = :name

      CHANNEL_API_ALLOW = %w[webhook_url hmac_mandatory additional_attributes].freeze
      CHANNEL_WEBWIDGET_ALLOW = %w[
        widget_color welcome_title welcome_tagline feature_flags reply_time
        pre_chat_form_enabled pre_chat_form_options continuity_via_email
      ].freeze
      CHANNEL_WHATSAPP_ALLOW = %w[provider].freeze
      CHANNEL_EMAIL_ALLOW = %w[
        imap_enabled imap_address imap_port imap_enable_ssl
        smtp_enabled smtp_address smtp_port smtp_enable_starttls_auto smtp_authentication
        provider email_signature
      ].freeze

      def to_h
        super.merge(
          'channel_attributes' => serialize_channel,
          'requires_credentials' => requires_credentials?
        )
      end

      private

      def serialize_channel
        channel = @record.channel
        return {} unless channel

        allow = allow_list_for(@record.channel_type)
        attrs = channel.attributes.slice(*allow)

        # Type-specific JSONB scrubbing for fields that ARE allow-listed but
        # whose value is a JSON blob that may carry secrets.
        case @record.channel_type
        when 'Channel::Whatsapp'
          # provider_config not allow-listed, but just in case future versions
          # add it back, this is defense-in-depth.
          attrs['provider_config'] = {} if attrs.key?('provider_config')
        when 'Channel::Email'
          attrs['provider_config'] = {} if attrs.key?('provider_config')
        end

        attrs
      end

      def allow_list_for(channel_type)
        case channel_type
        when 'Channel::Api' then CHANNEL_API_ALLOW
        when 'Channel::WebWidget' then CHANNEL_WEBWIDGET_ALLOW
        when 'Channel::Whatsapp' then CHANNEL_WHATSAPP_ALLOW
        when 'Channel::Email' then CHANNEL_EMAIL_ALLOW
        else [] # unsupported channel type in v1 — exports only Inbox shell
        end
      end

      def requires_credentials?
        %w[Channel::Whatsapp Channel::Email Channel::Api].include?(@record.channel_type)
      end
    end
  end
end
