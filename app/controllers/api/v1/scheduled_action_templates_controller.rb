# frozen_string_literal: true

class Api::V1::ScheduledActionTemplatesController < Api::V1::BaseController
  before_action :set_template, only: [:show, :update, :destroy]
  before_action :check_authorization, only: [:update, :destroy]

  def index
    @templates = fetch_templates

    apply_pagination
    
    paginated_response(
      data: ScheduledActionTemplateSerializer.serialize_collection(@templates, include_creator: true),
      collection: @templates
    )
  end

  def show
    success_response(
      data: ScheduledActionTemplateSerializer.serialize(@template, include_creator: true),
      message: 'Scheduled action template retrieved successfully'
    )
  end

  def create
    @template = ScheduledActionTemplate.new(template_params)
    @template.created_by = current_user.id

    if @template.save
      success_response(
        data: ScheduledActionTemplateSerializer.serialize(@template, include_creator: true),
        message: 'Scheduled action template created successfully',
        status: :created
      )
    else
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Template validation failed',
        details: @template.errors
      )
    end
  end

  def update
    if @template.update(template_update_params)
      success_response(
        data: ScheduledActionTemplateSerializer.serialize(@template, include_creator: true),
        message: 'Scheduled action template updated successfully'
      )
    else
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Template validation failed',
        details: @template.errors
      )
    end
  end

  def destroy
    @template.destroy
    
    success_response(
      data: nil,
      message: 'Scheduled action template deleted successfully'
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    error_response(
      code: ApiErrorCodes::CANNOT_DELETE_RESOURCE,
      message: e.message
    )
  end

  def apply
    # Apply a template to create a scheduled action
    template = ScheduledActionTemplate.find(params[:template_id])

    action_params = {
      contact_id: params[:contact_id],
      deal_id: params[:deal_id],
      conversation_id: params[:conversation_id],
      scheduled_for: params[:scheduled_for] || template.default_delay_minutes.minutes.from_now,
      notify_user_id: params[:notify_user_id]
    }

    @scheduled_action = template.create_scheduled_action!(
      nil,
      params[:contact_id],
      action_params
    )

    success_response(
      data: ScheduledActionSerializer.serialize(@scheduled_action),
      message: 'Template applied and scheduled action created successfully'
    )
  rescue StandardError => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  private

  def set_template
    @template = ScheduledActionTemplate.find(params[:id])
  end

  def check_authorization
    authorize @template, policy_class: ScheduledActionTemplatePolicy
  end

  def fetch_templates
    templates = ScheduledActionTemplate.all

    # Filter by action type
    templates = templates.by_action_type(params[:action_type]) if params[:action_type].present?

    # Filter by name/search
    templates = templates.by_name(params[:search]) if params[:search].present?

    # Filter by default
    templates = templates.defaults if params[:is_default] == 'true'

    # Filter by public
    templates = templates.public_templates if params[:is_public] == 'true'

    # Sort
    templates = if params[:sort] == 'name'
                  templates.order(name: :asc)
                else
                  templates.recent
                end

    templates
  end

  def template_params
    params.require(:scheduled_action_template).permit(
      :name,
      :description,
      :action_type,
      :default_delay_minutes,
      :is_default,
      :is_public,
      payload: {}
    )
  end

  def template_update_params
    params.require(:scheduled_action_template).permit(
      :name,
      :description,
      :default_delay_minutes,
      :is_default,
      :is_public,
      payload: {}
    )
  end

  def template_json(template)
    {
      id: template.id,
      name: template.name,
      description: template.description,
      action_type: template.action_type,
      default_delay_minutes: template.default_delay_minutes,
      payload: template.payload,
      is_default: template.is_default,
      is_public: template.is_public,
      creator: {
        id: template.creator.id,
        name: template.creator.name,
        email: template.creator.email
      },
      created_at: template.created_at,
      updated_at: template.updated_at
    }
  end

  def scheduled_action_json(action)
    {
      id: action.id,
      contact_id: action.contact_id,
      action_type: action.action_type,
      status: action.status,
      scheduled_for: action.scheduled_for,
      template_id: action.template_id,
      created_by: action.created_by,
      created_at: action.created_at
    }
  end
end
