# frozen_string_literal: true

module Templates
  module CategoryImporters
    # Creates Channel::* record first, then the Inbox pointing at it.
    # The Inbox name is prefixed with "[Configurar] " when the channel type
    # requires credentials (Whatsapp, Email, Api) so users notice they need to
    # re-connect before using it.
    class InboxesImporter < Base
      CATEGORY = 'inboxes'
      MODEL = ::Inbox
      UNIQUE_FIELD = :name

      CHANNEL_CLASS_MAP = {
        'Channel::Api' => Channel::Api,
        'Channel::WebWidget' => Channel::WebWidget,
        'Channel::Whatsapp' => Channel::Whatsapp,
        'Channel::Email' => Channel::Email
      }.freeze

      private

      def import_one(item, _idx)
        channel_type = item['channel_type']
        channel_class = CHANNEL_CLASS_MAP[channel_type]

        unless channel_class
          @report << {
            'category' => CATEGORY,
            'slug' => item['slug'],
            'status' => 'skipped',
            'reason' => "channel_type #{channel_type} not supported for import in v1"
          }
          return
        end

        attrs = item.except('slug', 'channel_attributes', 'channel_type', 'requires_credentials')

        # Prefix name when credentials are needed.
        if item['requires_credentials']
          attrs['name'] = "[Configurar] #{attrs['name']}"
        end

        result = @conflict_resolver.resolve(::Inbox, :name, attrs['name'])
        attrs['name'] = result[:value]

        # Build channel with credentials forcibly zeroed (defense in depth).
        channel_attrs = (item['channel_attributes'] || {}).dup
        zero_channel_secrets!(channel_type, channel_attrs)
        channel = channel_class.create!(channel_attrs)

        inbox = ::Inbox.create!(
          attrs.merge('channel_id' => channel.id, 'channel_type' => channel_type)
        )

        @id_remapper.register(CATEGORY, item['slug'], inbox.id)

        @report << {
          'category' => CATEGORY,
          'slug' => item['slug'],
          'status' => result[:renamed] ? 'renamed' : 'created',
          'new_id' => inbox.id,
          'new_name' => attrs['name'],
          'warning' => item['requires_credentials'] ? 'configure_credentials' : nil
        }.compact
      end

      def zero_channel_secrets!(channel_type, attrs)
        case channel_type
        when 'Channel::Api'
          attrs.delete('hmac_token')
          attrs.delete('identifier')
        when 'Channel::WebWidget'
          attrs.delete('hmac_token')
          attrs.delete('website_token')
        when 'Channel::Whatsapp'
          # phone_number is NOT NULL + UNIQUE. Use a placeholder that's unique
          # enough that the user is forced to change it before connecting.
          attrs['phone_number'] = "+0#{SecureRandom.hex(7)}"
          attrs['provider_config'] = {}
          attrs['provider_connection'] = {}
        when 'Channel::Email'
          # email and forward_to_email are NOT NULL + UNIQUE. Placeholder.
          placeholder = "configure-#{SecureRandom.hex(6)}@example.invalid"
          attrs['email'] = placeholder
          attrs['forward_to_email'] = placeholder
          attrs['imap_password'] = ''
          attrs['smtp_password'] = ''
          attrs['provider_config'] = {}
        end
      end
    end
  end
end
