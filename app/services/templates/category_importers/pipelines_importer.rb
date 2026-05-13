# frozen_string_literal: true

module Templates
  module CategoryImporters
    class PipelinesImporter < Base
      CATEGORY = 'pipelines'
      MODEL = ::Pipeline
      UNIQUE_FIELD = :name

      private

      def attributes_for(item)
        attrs = item.except('slug', 'stages', 'service_definitions')
        attrs['created_by_id'] = @current_user.id
        # Defensive: only one is_default=true allowed globally.
        attrs['is_default'] = false if attrs['is_default'] && ::Pipeline.where(is_default: true).exists?
        attrs
      end

      def after_create(record, item)
        super
        create_stages(record, item['stages'] || [])
        create_service_definitions(record, item['service_definitions'] || [])
      end

      def create_stages(pipeline, stages)
        stages.sort_by { |s| s['position'].to_i }.each do |stage_data|
          attrs = stage_data.except('slug')
          stage = pipeline.pipeline_stages.create!(attrs)
          @id_remapper.register('pipeline_stages', stage_data['slug'], stage.id) if stage_data['slug']
        end
      end

      def create_service_definitions(pipeline, defs)
        defs.each do |def_data|
          attrs = def_data.except('slug')
          sd = pipeline.pipeline_service_definitions.create!(attrs)
          @id_remapper.register('pipeline_service_definitions', def_data['slug'], sd.id) if def_data['slug']
        end
      end
    end
  end
end
