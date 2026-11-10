# The card must sit in a pipeline the creator can open, the same reach the
# executor gives them; the service creator (journeys) reaches every card.
module ScheduledActionPipelineItemTarget
  extend ActiveSupport::Concern

  included do
    belongs_to :pipeline_item, optional: true
    validate :pipeline_item_must_be_reachable
  end

  private

  # The uuid column turns a malformed id into nil, so the raw value is what says
  # a card was asked for.
  def pipeline_item_must_be_reachable
    return if pipeline_item_id_before_type_cast.blank?
    return if pipeline_item_id.present? && !will_save_change_to_pipeline_item_id?
    return if pipeline_item_id.present? && reachable_pipeline_items.exists?(id: pipeline_item_id)

    errors.add(:pipeline_item_id, 'must be an existing pipeline item')
  end

  def reachable_pipeline_items
    return PipelineItem.all if creator&.email == ScheduledAction::SERVICE_CREATOR_EMAIL

    PipelineItem.visible_to(creator)
  end
end
