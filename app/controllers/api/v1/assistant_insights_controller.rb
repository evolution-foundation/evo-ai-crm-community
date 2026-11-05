# frozen_string_literal: true

# Counts behind the assistant's proactive insights. A backend scheduler calls these with
# the service token and names the user in `user_id`; the answer is what THAT user can see,
# not the service token's see-everything scope, so one account's insight never reaches a
# user who cannot open the funnel it talks about.
class Api::V1::AssistantInsightsController < Api::V1::BaseController
  DEFAULT_STALE_DAYS = 7

  before_action :require_service_token
  before_action :set_target_user

  # GET /api/v1/assistant_insights/stale_pipeline_items?user_id=&days=7
  #
  # Active cards whose time in the current stage exceeds `days`, per active pipeline the
  # user can read. "In the current stage" is the same clock the stage-stagnation rules use:
  # the last stage movement, or the card's entry when it never moved.
  def stale_pipeline_items
    days = positive_integer_param(:days, DEFAULT_STALE_DAYS)
    counts = can_read_pipelines? ? stale_item_counts(days.days.ago) : {}
    names = Pipeline.where(id: counts.keys).pluck(:id, :name).to_h

    success_response(
      data: {
        days: days,
        pipelines: counts.map { |id, count| { id: id, name: names[id], stale_count: count } }
                         .sort_by { |row| row[:name].to_s }
      },
      message: 'Stale pipeline items counted successfully'
    )
  end

  private

  def require_service_token
    return if service_authenticated?

    error_response(ApiErrorCodes::FORBIDDEN, 'Service token required', status: :forbidden)
  end

  def set_target_user
    @target_user = User.find_by(id: params[:user_id]) if params[:user_id].present?
    return if @target_user

    error_response(ApiErrorCodes::USER_NOT_FOUND, 'User not found', status: :not_found)
  end

  def positive_integer_param(key, default)
    value = params[key].to_i
    value.positive? ? value : default
  end

  # Same gate as PipelinePolicy#show?, evaluated for the target user.
  def can_read_pipelines?
    @target_user.administrator? || @target_user.has_permission?('pipelines.read')
  end

  def stale_item_counts(cutoff)
    last_moved_at = StageMovement.where('stage_movements.pipeline_item_id = pipeline_items.id')
                                 .select('MAX(stage_movements.created_at)')

    PipelineItem.where(completed_at: nil)
                .where(pipeline_id: Pipeline.accessible_by(@target_user).where(is_active: true).select(:id))
                .where(
                  "COALESCE((#{last_moved_at.to_sql}), pipeline_items.entered_at, pipeline_items.created_at) < ?",
                  cutoff
                )
                .group(:pipeline_id)
                .count
  end
end
