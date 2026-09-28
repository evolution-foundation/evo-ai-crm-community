# frozen_string_literal: true

module Templates
  # Resolves name collisions during import by renaming: " (Template <name>)", then
  # " (2)", " (3)"... A plain resolver suffixes " template <name>" and " <n>" instead,
  # for a field whose format rejects parentheses. #resolve_always_suffixed skips the
  # check on the original value. Returns { value:, renamed: }.
  class ConflictResolver
    def initialize(template_name, case_sensitive: true, plain: false)
      @template_name = template_name.presence || 'Template'
      @case_sensitive = case_sensitive
      @plain = plain
    end

    # Same template, for a model that rejects a name differing only in case
    # (case_sensitive: false) or a field that takes only letters, digits and spaces.
    def with(case_sensitive: true, plain: false)
      self.class.new(@template_name, case_sensitive: case_sensitive, plain: plain)
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
      candidate = candidate_for(value, nil)
      counter = 2
      while collision?(within, field, candidate, scope)
        candidate = candidate_for(value, counter)
        counter += 1
        break if counter > 1000 # safety cap; nothing in v1 should hit this
      end

      { value: candidate, renamed: true }
    end

    def candidate_for(value, counter)
      if @plain
        template = @template_name.gsub(/[^\p{L}\p{N}]+/, ' ').strip
        return [value, 'template', template, counter].compact_blank.join(' ')
      end

      candidate = "#{value} (Template #{@template_name})"
      counter ? "#{candidate} (#{counter})" : candidate
    end

    def collision?(within, field, value, scope)
      relation = @case_sensitive ? within.where(field => value) : within.where(lower_eq(within.klass.arel_table[field], value))
      relation = relation.where(scope) if scope.any?
      relation.exists?
    end

    def lower_eq(column, value)
      column.lower.eq(Arel::Nodes::NamedFunction.new('LOWER', [Arel::Nodes.build_quoted(value)]))
    end
  end
end
