# frozen_string_literal: true

module Templates
  # Resolves UNIQUE-constraint collisions during import using rename-with-suffix.
  #
  # Algorithm: try original value. If it collides within the given relation,
  # append " (Template <name>)". If that still collides, append " (2)", " (3)", ...
  # #resolve_always_suffixed skips the first check and starts at the suffix.
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
    # @param within [ActiveRecord::Relation] records a collision is looked up in.
    #   The report tells the caller whether a name collided, so for a category the
    #   caller reads only in part this must be what they read.
    # @return [Hash] { value: String, renamed: Boolean }
    def resolve(model_class, field, value, scope: {}, within: model_class.all)
      return { value: value, renamed: false } if value.blank?
      return { value: value, renamed: false } unless collision?(within, field, value, scope)

      suffixed(within, field, value, scope)
    end

    # Renames even when the original value is free, so the result says nothing
    # about whether it exists. Same parameters as #resolve.
    def resolve_always_suffixed(model_class, field, value, scope: {}, within: model_class.all)
      return { value: value, renamed: false } if value.blank?

      suffixed(within, field, value, scope)
    end

    private

    def suffixed(within, field, value, scope)
      candidate = "#{value} (Template #{@template_name})"
      counter = 2
      while collision?(within, field, candidate, scope)
        candidate = "#{value} (Template #{@template_name}) (#{counter})"
        counter += 1
        break if counter > 1000 # safety cap; nothing in v1 should hit this
      end

      { value: candidate, renamed: true }
    end

    def collision?(within, field, value, scope)
      relation = within.where(field => value)
      relation = relation.where(scope) if scope.any?
      relation.exists?
    end
  end
end
