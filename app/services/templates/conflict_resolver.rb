# frozen_string_literal: true

module Templates
  # Resolves UNIQUE-constraint collisions during import using rename-with-suffix.
  #
  # Algorithm: try original value. If it collides in the DB, append
  # " (Template <name>)". If that still collides, append " (2)", " (3)", ...
  # Returns { value:, renamed: }.
  class ConflictResolver
    def initialize(template_name)
      @template_name = template_name.presence || 'Template'
    end

    # Resolves a single unique field.
    #
    # @param model_class [Class] AR model (e.g. Label)
    # @param field [Symbol] field name (e.g. :title)
    # @param value [String] original value
    # @param scope [Hash] optional WHERE scope for compound-unique fields
    # @return [Hash] { value: String, renamed: Boolean }
    def resolve(model_class, field, value, scope: {})
      return { value: value, renamed: false } if value.blank?
      return { value: value, renamed: false } unless collision?(model_class, field, value, scope)

      candidate = "#{value} (Template #{@template_name})"
      counter = 2
      while collision?(model_class, field, candidate, scope)
        candidate = "#{value} (Template #{@template_name}) (#{counter})"
        counter += 1
        break if counter > 1000 # safety cap; nothing in v1 should hit this
      end

      { value: candidate, renamed: true }
    end

    private

    def collision?(model_class, field, value, scope)
      relation = model_class.where(field => value)
      relation = relation.where(scope) if scope.any?
      relation.exists?
    end
  end
end
