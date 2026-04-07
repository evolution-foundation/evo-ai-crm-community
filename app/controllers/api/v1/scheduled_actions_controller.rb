# frozen_string_literal: true

class Api::V1::ScheduledActionsController < Api::V1::BaseController
  before_action :set_scheduled_action, only: [:show, :update, :destroy]
  before_action :check_authorization, only: [:update, :destroy]

  def index
    @scheduled_actions = fetch_scheduled_actions
    apply_pagination
    
    paginated_response(
      data: ScheduledActionSerializer.serialize_collection(@scheduled_actions),
      collection: @scheduled_actions
    )
  end

  def show
    success_response(
      data: ScheduledActionSerializer.serialize(@scheduled_action),
      message: 'Scheduled action retrieved successfully'
    )
  end

  def create
    @scheduled_action = ScheduledAction.new(scheduled_action_params)
    
    # Set created_by - use current_user if available, otherwise use a system user for service token auth
    if current_user.present?
      @scheduled_action.created_by = current_user.id
    elsif service_authenticated?
      # For service-to-service calls, find a system user or first global admin
      system_user = User.find_by(email: 'system@evoai.app')
      if system_user
        @scheduled_action.created_by = system_user.id
        Rails.logger.info "ScheduledAction: Using system user #{system_user.id} (#{system_user.class.name}) for service token auth"
      else
        Rails.logger.error "ScheduledAction: No system user or global admin found for service token auth"
        error_response(
          code: ApiErrorCodes::INTERNAL_ERROR,
          message: 'No system user available for service token authentication'
        )
        return
      end
    end

    if @scheduled_action.save
      success_response(
        data: ScheduledActionSerializer.serialize(@scheduled_action),
        message: 'Scheduled action created successfully',
        status: :created
      )
    else
      Rails.logger.error "ScheduledAction validation failed: #{@scheduled_action.errors.full_messages.join(', ')}"
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Scheduled action validation failed',
        details: @scheduled_action.errors,
        status: :unprocessable_entity
      )
    end
  rescue StandardError => e
    Rails.logger.error "ScheduledAction creation error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    error_response(
      ApiErrorCodes::INTERNAL_ERROR,
      e.message,
      status: :internal_server_error
    )
  end

  def update
    if @scheduled_action.update(scheduled_action_update_params)
      success_response(
        data: ScheduledActionSerializer.serialize(@scheduled_action),
        message: 'Scheduled action updated successfully'
      )
    else
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Scheduled action validation failed',
        details: @scheduled_action.errors
      )
    end
  end

  def destroy
    @scheduled_action.mark_as_cancelled!
    
    success_response(
      data: nil,
      message: 'Scheduled action cancelled successfully'
    )
  rescue StandardError => e
    error_response(
      code: ApiErrorCodes::INTERNAL_ERROR,
      message: e.message
    )
  end

  def by_deal
    deal_id = params[:deal_id]
    @scheduled_actions = ScheduledAction.all
                                .for_deal(deal_id)
                                .by_scheduled_time
    apply_pagination

    paginated_response(
      data: ScheduledActionSerializer.serialize_collection(@scheduled_actions),
      collection: @scheduled_actions,
      message: 'Scheduled actions retrieved successfully'
    )
  end

  def by_contact
    contact_id = params[:contact_id]
    @scheduled_actions = ScheduledAction.all
                                .for_contact(contact_id)
                                .by_scheduled_time
    apply_pagination

    paginated_response(
      data: ScheduledActionSerializer.serialize_collection(@scheduled_actions),
      collection: @scheduled_actions,
      message: 'Scheduled actions retrieved successfully'
    )
  end

  private

  def set_scheduled_action
    @scheduled_action = ScheduledAction.find(params[:id])
  end

  def check_authorization
    authorize @scheduled_action
  end

  def fetch_scheduled_actions
    actions = ScheduledAction.all

    # Filter by status
    actions = actions.by_status(params[:status]) if params[:status].present?

    # Filter by action type
    actions = actions.by_action_type(params[:action_type]) if params[:action_type].present?

    # Filter by deal
    actions = actions.for_deal(params[:deal_id]) if params[:deal_id].present?

    # Filter by contact
    actions = actions.for_contact(params[:contact_id]) if params[:contact_id].present?

    # Filter by conversation
    actions = actions.for_conversation(params[:conversation_id]) if params[:conversation_id].present?

    # Filter by date range
    if params[:scheduled_from].present?
      actions = actions.where('scheduled_for >= ?', params[:scheduled_from])
    end

    if params[:scheduled_to].present?
      actions = actions.where('scheduled_for <= ?', params[:scheduled_to])
    end

    # Sort
    actions = if params[:sort] == 'recent'
                actions.recent
              else
                actions.by_scheduled_time
              end

    actions
  end

  def scheduled_action_params
    params.require(:scheduled_action).permit(
      :deal_id,
      :contact_id,
      :conversation_id,
      :action_type,
      :scheduled_for,
      :template_id,
      :max_retries,
      :recurrence_type,
      payload: {},
      recurrence_config: {}
    )
  end

  def scheduled_action_update_params
    params.require(:scheduled_action).permit(
      :scheduled_for,
      :max_retries,
      payload: {},
      recurrence_config: {}
    )
  end

  def scheduled_action_json(action)
    {
      id: action.id,
      deal_id: action.deal_id,
      contact_id: action.contact_id,
      conversation_id: action.conversation_id,
      action_type: action.action_type,
      status: action.status,
      scheduled_for: action.scheduled_for,
      executed_at: action.executed_at,
      payload: action.payload,
      template_id: action.template_id,
      created_by: action.created_by,
      retry_count: action.retry_count,
      max_retries: action.max_retries,
      error_message: action.error_message,
      recurrence_type: action.recurrence_type,
      recurrence_config: action.recurrence_config,
      time_until_execution: action.time_until_execution,
      formatted_time_until: action.formatted_time_until,
      overdue: action.overdue?,
      can_retry: action.can_retry?,
      creator: action.creator ? {
        id: action.creator.id,
        name: action.creator.name,
        email: action.creator.email
      } : nil,
      created_at: action.created_at,
      updated_at: action.updated_at
    }
  end
end

