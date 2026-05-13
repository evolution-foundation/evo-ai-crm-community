# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Base class for per-category serializers used during export.
    # Subclasses define ALLOW_LIST and override #serialize_record if needed.
    class Base
      class << self
        # Returns an array of plain hashes suitable for JSON.dump.
        # `records` is an enumerable of ActiveRecord rows for this category.
        def serialize_all(records)
          Array(records).map { |record| new(record).to_h }
        end
      end

      def initialize(record)
        @record = record
      end

      # Default: pick allow-listed attributes and tag with a slug.
      def to_h
        base = @record.attributes.slice(*self.class::ALLOW_LIST)
        base['slug'] = slug
        base
      end

      # Slug used to identify this record in the bundle. Defaults to the value
      # of the model's natural identifying column.
      def slug
        Templates::IdRemapper.slug_for(@record.public_send(self.class::SLUG_FIELD))
      end
    end
  end
end
