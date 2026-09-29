# frozen_string_literal: true

module Templates
  class ExportService
    Result = Struct.new(:filename, :io, keyword_init: true)

    def initialize(selection:, template_name:, description:, author:, current_user:)
      @selection = selection
      @template_name = template_name
      @description = description
      @current_user = current_user
      @author = author.presence || current_user.try(:name) || 'Unknown'
    end

    def perform
      builder = BundleBuilder.new(
        selection: @selection,
        template_name: @template_name,
        description: @description,
        author: @author,
        current_user: @current_user
      )
      Result.new(filename: builder.filename, io: builder.build)
    end

    # Returns the inventory of exportable entities grouped by category.
    # Used by the frontend wizard to render checkboxes.
    # A category the caller may not read is left out, and never queried.
    def self.exportable_inventory(current_user:)
      INVENTORY.select { |category, _| CategoryPermission.readable?(category, current_user) }
               .transform_values { |list| list.call(current_user) }
    end

    named = ->(rows) { rows.map { |id, name| { id: id, name: name } } }
    # Macros, pipelines and inboxes are read in part and go through VisibilityScope.for;
    # the rest is account-wide.
    INVENTORY = {
      'pipelines' => ->(user) { named.call(VisibilityScope.for('pipelines', ::Pipeline, user).reorder(:name).pluck(:id, :name)) },
      'agents' => ->(_user) { named.call(::AgentBot.order(:name).pluck(:id, :name)) },
      'teams' => ->(_user) { named.call(::Team.order(:name).pluck(:id, :name)) },
      'labels' => ->(_user) { named.call(::Label.order(:title).pluck(:id, :title)) },
      'custom_attributes' => lambda { |_user|
        ::CustomAttributeDefinition.order(:attribute_display_name)
                                   .pluck(:id, :attribute_display_name, :attribute_model)
                                   .map { |id, name, model| { id: id, name: "#{name} (#{model})" } }
      },
      'canned_responses' => ->(_user) { named.call(::CannedResponse.order(:short_code).pluck(:id, :short_code)) },
      'macros' => ->(user) { named.call(VisibilityScope.for('macros', ::Macro, user).reorder(:name).pluck(:id, :name)) },
      'inboxes' => lambda { |user|
        VisibilityScope.for('inboxes', ::Inbox, user).reorder(:name).pluck(:id, :name, :channel_type)
                       .map { |id, name, ct| { id: id, name: "#{name} (#{ct.demodulize})" } }
      },
      'message_templates' => ->(_user) { named.call(::MessageTemplate.order(:name).pluck(:id, :name)) }
    }.freeze
    private_constant :INVENTORY
  end
end
