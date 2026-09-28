# frozen_string_literal: true

module Templates
  module CategoryImporters
    # Base class for per-category importers used during import.
    #
    # Sub-class contract:
    # - CATEGORY: the bundle category string (e.g. "labels")
    # - MODEL: the AR class to create
    # - UNIQUE_FIELD: field used to detect conflicts (used by ConflictResolver)
    # - SCOPE_FIELDS: optional fields to scope UNIQUE_FIELD lookup (e.g. for
    #   compound-unique constraints like message_templates.name+channel)
    # - ALWAYS_SUFFIX: optional; rename every record instead of only colliding ones
    # - CASE_INSENSITIVE: optional; the model rejects a name that differs only in case
    # - PLAIN_SUFFIX: optional; UNIQUE_FIELD's format rejects the default suffix
    #
    # Sub-classes typically override #attributes_for to map the bundle hash to
    # model attributes, and #after_create to register the slug for IdRemapper.
    class Base
      ALWAYS_SUFFIX = false
      CASE_INSENSITIVE = false
      PLAIN_SUFFIX = false

      attr_reader :report

      def initialize(items, id_remapper:, conflict_resolver:, current_user:)
        @items = Array(items)
        @id_remapper = id_remapper
        @conflict_resolver = conflict_resolver
        @current_user = current_user
        @report = []
      end

      def import!
        @items.each_with_index do |item, idx|
          import_one(item, idx)
        end
        @report
      end

      private

      def import_one(item, idx)
        attrs = attributes_for(item)
        Templates::Sanitizer.zero_blocked_fields!(self.class::CATEGORY, attrs)

        original_value = attrs[self.class::UNIQUE_FIELD.to_s]
        result = resolve_unique_value(original_value, item)
        attrs[self.class::UNIQUE_FIELD.to_s] = result[:value]

        record = self.class::MODEL.create!(attrs)
        after_create(record, item)

        @report << {
          'category' => self.class::CATEGORY,
          'slug' => item['slug'],
          'status' => result[:renamed] ? 'renamed' : 'created',
          'new_id' => record.id,
          'new_name' => result[:value],
          'original_name' => result[:renamed] ? original_value : nil
        }.compact
      rescue ActiveRecord::RecordInvalid => e
        # Re-raise so the outer transaction rolls back.
        raise e
      end

      def resolve_unique_value(value, item)
        resolver = @conflict_resolver.with(case_sensitive: !self.class::CASE_INSENSITIVE, plain: self.class::PLAIN_SUFFIX)
        resolver.public_send(
          self.class::ALWAYS_SUFFIX ? :resolve_always_suffixed : :resolve,
          self.class::MODEL,
          self.class::UNIQUE_FIELD,
          value,
          scope: scope_for(item),
          within: collision_scope
        )
      end

      # Hook: build attribute hash from a bundle item. Default: shallow copy
      # minus 'slug' (which is bundle-only metadata, not a column).
      def attributes_for(item)
        item.except('slug')
      end

      # Hook: register slug in IdRemapper or perform any post-create work.
      def after_create(record, item)
        @id_remapper.register(self.class::CATEGORY, item['slug'], record.id)
      end

      # Hook: extra WHERE scope for conflict detection (e.g. compound-unique).
      def scope_for(_item)
        {}
      end

      # Hook: the records a name collision is looked up in. The report says whether
      # a name collided, so it may only consult what the caller already reads.
      def collision_scope
        Templates::VisibilityScope.for(self.class::CATEGORY, self.class::MODEL, @current_user)
      end
    end
  end
end
