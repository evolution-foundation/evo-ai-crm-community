# frozen_string_literal: true

module Templates
  module CategoryImporters
    class CustomAttributesImporter < Base
      CATEGORY = 'custom_attributes'
      MODEL = ::CustomAttributeDefinition
      UNIQUE_FIELD = :attribute_key

      private

      # attribute_key is unique per attribute_model, so scope the lookup.
      def scope_for(item)
        { attribute_model: item['attribute_model'] }
      end
    end
  end
end
