# frozen_string_literal: true

module Templates
  class ExportService
    Result = Struct.new(:filename, :io, keyword_init: true)

    def initialize(selection:, template_name:, description:, author:, current_user:)
      @selection = selection
      @template_name = template_name
      @description = description
      @author = author.presence || current_user.try(:name) || 'Unknown'
    end

    def perform
      builder = BundleBuilder.new(
        selection: @selection,
        template_name: @template_name,
        description: @description,
        author: @author
      )
      Result.new(filename: builder.filename, io: builder.build)
    end

    # Returns the inventory of exportable entities grouped by category.
    # Used by the frontend wizard to render checkboxes.
    def self.exportable_inventory
      {
        'pipelines' => ::Pipeline.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
        'agents' => ::AgentBot.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
        'teams' => ::Team.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
        'labels' => ::Label.order(:title).pluck(:id, :title).map { |id, name| { id: id, name: name } },
        'custom_attributes' => ::CustomAttributeDefinition.order(:attribute_display_name)
          .pluck(:id, :attribute_display_name, :attribute_model)
          .map { |id, name, model| { id: id, name: "#{name} (#{model})" } },
        'canned_responses' => ::CannedResponse.order(:short_code).pluck(:id, :short_code).map { |id, name| { id: id, name: name } },
        'macros' => ::Macro.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
        'inboxes' => ::Inbox.order(:name).pluck(:id, :name, :channel_type)
          .map { |id, name, ct| { id: id, name: "#{name} (#{ct.demodulize})" } },
        'message_templates' => ::MessageTemplate.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } }
      }
    end
  end
end
