# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Macros: actions jsonb may contain send_webhook_event with URL — sanitized.
    class MacrosSerializer < Base
      ALLOW_LIST = %w[name visibility].freeze
      SLUG_FIELD = :name

      def to_h
        base = super
        base['actions'] = Templates::Sanitizer.scrub_macro_actions(@record.actions)
        base
      end
    end
  end
end
