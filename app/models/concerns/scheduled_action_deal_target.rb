# The pipeline card a scheduled action targets. `deal_id` holds the card's uuid;
# the card must sit in a pipeline the creator can open, the same reach the
# executor gives them, and the service creator (journeys) reaches every card.
module ScheduledActionDealTarget
  extend ActiveSupport::Concern

  included do
    belongs_to :deal, class_name: 'PipelineItem', optional: true
    validate :deal_must_exist
  end

  private

  # The uuid column turns a malformed id into nil, so the raw value is what says
  # a deal was asked for.
  def deal_must_exist
    return if deal_id_before_type_cast.blank? || (deal_id.present? && !will_save_change_to_deal_id?)
    return if deal_id.present? && reachable_deals.exists?(id: deal_id)

    errors.add(:deal_id, 'must be an existing pipeline item')
  end

  def reachable_deals
    return PipelineItem.all if creator&.email == ScheduledAction::SERVICE_CREATOR_EMAIL

    PipelineItem.visible_to(creator)
  end
end
