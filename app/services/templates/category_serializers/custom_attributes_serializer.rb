# frozen_string_literal: true

module Templates
  module CategorySerializers
    class CustomAttributesSerializer < Base
      ALLOW_LIST = %w[
        attribute_key
        attribute_display_name
        attribute_description
        attribute_model
        attribute_display_type
        attribute_values
        default_value
        regex_pattern
        regex_cue
      ].freeze
      SLUG_FIELD = :attribute_key

      def slug
        # attribute_key is unique per attribute_model; namespace the slug to avoid
        # collisions across models.
        Templates::IdRemapper.slug_for("#{@record.attribute_model}-#{@record.attribute_key}")
      end
    end
  end
end
