# frozen_string_literal: true

module Templates
  module CategoryImporters
    # Macros have no UNIQUE constraint on name, so ConflictResolver is a no-op.
    # We still re-scrub actions on import in case the bundle was edited manually.
    class MacrosImporter < Base
      CATEGORY = 'macros'
      MODEL = ::Macro
      UNIQUE_FIELD = :name

      private

      def attributes_for(item)
        attrs = item.except('slug')
        attrs['actions'] = Templates::Sanitizer.scrub_macro_actions(attrs['actions'])
        attrs['created_by_id'] = @current_user.id
        attrs['updated_by_id'] = @current_user.id
        attrs
      end
    end
  end
end
