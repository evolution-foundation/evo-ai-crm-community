# frozen_string_literal: true

module Templates
  module CategorySerializers
    # MessageTemplate is scoped per channel (polymorphic channel_id + channel_type).
    # We reference the parent inbox by slug so the importer can re-link via IdRemapper.
    class MessageTemplatesSerializer < Base
      ALLOW_LIST = %w[
        name content language category template_type media_type
        components variables settings metadata active
      ].freeze
      SLUG_FIELD = :name

      def to_h
        super.merge(
          'inbox_slug' => inbox_slug
        )
      end

      private

      def inbox_slug
        # channel_id points to the channel record; we walk to the Inbox.
        inbox = Inbox.find_by(channel_id: @record.channel_id, channel_type: @record.channel_type)
        inbox ? Templates::IdRemapper.slug_for(inbox.name) : nil
      end
    end
  end
end
