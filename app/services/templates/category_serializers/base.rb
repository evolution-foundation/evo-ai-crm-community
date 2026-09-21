# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Base class for per-category serializers used during export.
    # Subclasses define ALLOW_LIST and override #serialize_record if needed.
    class Base
      class << self
        # Returns an array of plain hashes suitable for JSON.dump.
        # `records` is an enumerable of ActiveRecord rows for this category.
        # `current_user` is the caller, for a serializer that names a record of
        # ANOTHER category and has to ask that category's visibility rule first.
        def serialize_all(records, current_user: nil)
          Array(records).map { |record| new(record, current_user: current_user).to_h }
        end
      end

      def initialize(record, current_user: nil)
        @record = record
        @current_user = current_user
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
