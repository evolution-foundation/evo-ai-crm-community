# frozen_string_literal: true

module Templates
  module CategorySerializers
    # Serializes Pipeline + nested PipelineStage + PipelineServiceDefinition.
    # Does NOT include PipelineTasks (those are work instances, not config).
    class PipelinesSerializer < Base
      ALLOW_LIST = %w[name description pipeline_type visibility is_active is_default config custom_fields].freeze
      SLUG_FIELD = :name

      STAGE_ALLOW_LIST = %w[name position color stage_type automation_rules custom_fields].freeze
      SERVICE_DEF_ALLOW_LIST = %w[name description default_value currency active].freeze

      def to_h
        super.merge(
          'stages' => serialize_stages,
          'service_definitions' => serialize_service_definitions
        )
      end

      private

      def serialize_stages
        @record.pipeline_stages.order(:position).map do |stage|
          stage.attributes.slice(*STAGE_ALLOW_LIST).merge(
            'slug' => Templates::IdRemapper.slug_for("#{@record.name}-#{stage.name}")
          )
        end
      end

      def serialize_service_definitions
        @record.pipeline_service_definitions.map do |sd|
          sd.attributes.slice(*SERVICE_DEF_ALLOW_LIST).merge(
            'slug' => Templates::IdRemapper.slug_for("#{@record.name}-#{sd.name}")
          )
        end
      end
    end
  end
end
