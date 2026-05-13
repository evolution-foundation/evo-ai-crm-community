# frozen_string_literal: true

module Templates
  module CategoryImporters
    # MessageTemplate is scoped per channel (polymorphic). The bundle carries
    # `inbox_slug`; we resolve it via IdRemapper to find the new inbox and use
    # its channel pointer.
    class MessageTemplatesImporter < Base
      CATEGORY = 'message_templates'
      MODEL = ::MessageTemplate
      UNIQUE_FIELD = :name

      private

      def import_one(item, _idx)
        inbox_id = @id_remapper.resolve('inboxes', item['inbox_slug'])
        inbox = inbox_id && ::Inbox.find_by(id: inbox_id)

        unless inbox
          @report << {
            'category' => CATEGORY,
            'slug' => item['slug'],
            'status' => 'skipped',
            'reason' => "inbox slug '#{item['inbox_slug']}' not found in import set"
          }
          return
        end

        attrs = item.except('slug', 'inbox_slug')
        attrs['channel_id'] = inbox.channel_id
        attrs['channel_type'] = inbox.channel_type

        result = @conflict_resolver.resolve(
          ::MessageTemplate, :name, attrs['name'],
          scope: { channel_id: inbox.channel_id, channel_type: inbox.channel_type }
        )
        attrs['name'] = result[:value]

        record = ::MessageTemplate.create!(attrs)
        @id_remapper.register(CATEGORY, item['slug'], record.id)

        @report << {
          'category' => CATEGORY,
          'slug' => item['slug'],
          'status' => result[:renamed] ? 'renamed' : 'created',
          'new_id' => record.id,
          'new_name' => attrs['name']
        }
      end
    end
  end
end
