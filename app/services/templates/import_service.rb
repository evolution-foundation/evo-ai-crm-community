# frozen_string_literal: true

module Templates
  # Orchestrates the import of a template bundle.
  # - Reads + validates ZIP via BundleReader (raises typed errors).
  # - Runs all category importers in topological order inside a single DB
  #   transaction so any failure rolls back the whole import.
  # - Suppresses Rails.configuration.dispatcher events for the duration to
  #   avoid event-broadcast storms.
  class ImportService
    Report = Struct.new(:manifest, :items, :warnings, keyword_init: true) do
      def to_h
        { manifest: manifest, items: items, warnings: warnings }
      end
    end

    # Import order: items first that nothing else references, then items that
    # may reference earlier ones. Inboxes BEFORE agents because AgentBotInbox
    # links the two (when we add that link). Message templates LAST because
    # they reference inboxes.
    IMPORT_ORDER = %w[
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

    IMPORTER_MAP = {
      'labels' => CategoryImporters::LabelsImporter,
      'teams' => CategoryImporters::TeamsImporter,
      'custom_attributes' => CategoryImporters::CustomAttributesImporter,
      'canned_responses' => CategoryImporters::CannedResponsesImporter,
      'macros' => CategoryImporters::MacrosImporter,
      'pipelines' => CategoryImporters::PipelinesImporter,
      'inboxes' => CategoryImporters::InboxesImporter,
      'agents' => CategoryImporters::AgentsImporter,
      'message_templates' => CategoryImporters::MessageTemplatesImporter
    }.freeze

    def initialize(uploaded_file:, current_user:)
      @uploaded_file = uploaded_file
      @current_user = current_user
    end

    def perform
      bundle = BundleReader.new(@uploaded_file).read
      template_name = bundle.manifest['name'].to_s

      id_remapper = IdRemapper.new
      conflict_resolver = ConflictResolver.new(template_name)
      all_items = []
      warnings = []

      DispatcherSuppression.with_suppressed do
        ActiveRecord::Base.transaction do
          IMPORT_ORDER.each do |category|
            items = bundle.categories[category]
            next if items.blank?

            importer = IMPORTER_MAP[category].new(
              items,
              id_remapper: id_remapper,
              conflict_resolver: conflict_resolver,
              current_user: @current_user
            )
            report_items = importer.import!
            all_items.concat(report_items)

            # Promote warnings to top-level for UI emphasis.
            report_items.each do |item|
              warnings << item if item['warning'] || item['status'] == 'skipped'
            end
          end
        end
      end

      Report.new(manifest: bundle.manifest, items: all_items, warnings: warnings)
    end
  end
end
