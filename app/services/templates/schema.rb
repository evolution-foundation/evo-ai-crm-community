# frozen_string_literal: true

module Templates
  # Bundle format constants and category registry.
  #
  # A bundle is a ZIP containing:
  #   manifest.json              # version, name, author, description, contents index
  #   <category>.json            # one file per category present
  #   assets/                    # optional binary assets (avatars, etc.)
  #
  # CATEGORIES order is also the topological import order: items earlier in the
  # list are imported first so later importers can resolve references via
  # IdRemapper.
  module Schema
    SCHEMA_VERSION = 1

    CATEGORIES = %w[
      labels
      teams
      custom_attributes
      canned_responses
      macros
      pipelines
      inboxes
      agents
      message_templates
    ].freeze

    MAX_BUNDLE_SIZE_BYTES = 50 * 1024 * 1024 # 50 MB
    MAX_ENTRIES = 10_000
    BUNDLE_EXTENSION = '.evotpl.zip'

    def self.valid_category?(category)
      CATEGORIES.include?(category.to_s)
    end

    def self.manifest_skeleton(name:, description:, author:, contents:)
      {
        schema_version: SCHEMA_VERSION,
        name: name,
        description: description,
        author: author,
        created_at: Time.zone.now.iso8601,
        evo_crm_version: defined?(EvoCrm::VERSION) ? EvoCrm::VERSION : nil,
        contents: contents
      }
    end
  end
end
