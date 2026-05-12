# == Schema Information
#
# Table name: stage_movements
#
#  id               :uuid             not null, primary key
#  movement_type    :integer          default("manual")
#  notes            :text
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  from_stage_id    :uuid
#  moved_by_id      :uuid
#  pipeline_item_id :uuid             not null
#  to_stage_id      :uuid             not null
#
# Indexes
#
#  index_stage_movements_on_pipeline_item_id  (pipeline_item_id)
#
# Foreign Keys
#
#  fk_rails_...  (from_stage_id => pipeline_stages.id)
#  fk_rails_...  (pipeline_item_id => pipeline_items.id)
#  fk_rails_...  (to_stage_id => pipeline_stages.id)
#
class StageMovement < ApplicationRecord
  belongs_to :pipeline_item
  belongs_to :from_stage, class_name: 'PipelineStage', optional: true
  belongs_to :to_stage, class_name: 'PipelineStage'
  belongs_to :moved_by, class_name: 'User', optional: true

  enum movement_type: {
    manual: 0,         # Movido manualmente por um usuário
    automated: 1,      # Movido por automação/regra
    system: 2,         # Movido pelo sistema (entrada no funil, etc)
    cross_pipeline: 3  # Conversa foi movida para outro pipeline (from/to em pipelines distintos)
  }

  validates :to_stage, presence: true
  validate :stages_belong_to_same_pipeline, unless: :cross_pipeline?

  scope :recent, -> { order(created_at: :desc) }
  scope :for_pipeline, lambda { |pipeline|
    joins(pipeline_item: :pipeline).where(pipeline_items: { pipeline: pipeline })
  }

  def duration_in_previous_stage
    return nil unless from_stage

    previous_movement = pipeline_item.stage_movements
                                             .where('created_at < ?', created_at)
                                             .order(created_at: :desc)
                                             .first

    if previous_movement
      ((created_at - previous_movement.created_at) / 1.day).round(1)
    else
      ((created_at - pipeline_item.entered_at) / 1.day).round(1)
    end
  end

  def forward_movement?
    return true unless from_stage

    to_stage.position > from_stage.position
  end

  def backward_movement?
    return false unless from_stage

    to_stage.position < from_stage.position
  end

  def movement_description
    if from_stage
      "Moved from '#{from_stage.name}' to '#{to_stage.name}'"
    else
      "Added to pipeline in stage '#{to_stage.name}'"
    end
  end

  def push_event_data
    {
      id: id,
      from_stage: from_stage&.push_event_data,
      to_stage: to_stage.push_event_data,
      moved_by: moved_by&.push_event_data,
      movement_type: movement_type,
      notes: notes,
      created_at: created_at.to_i,
      duration_in_previous_stage: duration_in_previous_stage
    }
  end

  private

  def stages_belong_to_same_pipeline
    return unless from_stage && to_stage

    return unless from_stage.pipeline_id != to_stage.pipeline_id

    errors.add(:to_stage, 'must belong to the same pipeline as from_stage')
  end
end
