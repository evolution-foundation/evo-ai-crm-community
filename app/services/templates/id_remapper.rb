# frozen_string_literal: true

module Templates
  # Maps bundle slugs to newly-created record IDs so cross-references inside
  # the bundle (e.g. AgentBotInbox.allowed_label_ids referencing labels) can be
  # resolved during import.
  #
  # Usage:
  #   remapper = IdRemapper.new
  #   remapper.register('labels', 'urgente', new_label.id)
  #   remapper.resolve('labels', 'urgente') # => new_label.id
  class IdRemapper
    def initialize
      @map = Hash.new { |h, k| h[k] = {} }
      @skipped = Hash.new { |h, k| h[k] = Set.new }
    end

    # A slug the bundle carried but the import left out, so a dependent item can say
    # why its reference did not resolve.
    def skip(category, slug)
      @skipped[category.to_s] << slug.to_s if slug.present?
    end

    def skipped?(category, slug)
      @skipped[category.to_s].include?(slug.to_s)
    end

    def register(category, slug, new_id)
      raise ArgumentError, 'slug must be present' if slug.blank?

      @map[category.to_s][slug.to_s] = new_id
    end

    def resolve(category, slug)
      @map[category.to_s][slug.to_s]
    end

    def resolve_many(category, slugs)
      Array(slugs).filter_map { |slug| resolve(category, slug) }
    end

    # Generates a kebab-case slug for a record's identifying field.
    # Used by serializers to assign stable identifiers in the bundle.
    def self.slug_for(value)
      value.to_s
           .downcase
           .gsub(/[^a-z0-9]+/, '-')
           .gsub(/^-|-$/, '')
           .presence || 'item'
    end
  end
end
