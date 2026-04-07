class Api::V1::Integrations::HooksController < Api::V1::BaseController
  require_permissions({
    create: 'integrations.create',
    update: 'integrations.update',
    destroy: 'integrations.delete',
    process_event: 'integrations.execute'
  })

  before_action :fetch_hook, except: [:create]

  def create
    @hook = Integrations::Hook.create!(permitted_params)
    
    success_response(
      data: IntegrationHookSerializer.serialize(@hook),
      message: 'Integration hook created successfully',
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  def update
    @hook.update!(permitted_params.slice(:status, :settings))
    
    success_response(
      data: IntegrationHookSerializer.serialize(@hook),
      message: 'Integration hook updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  def process_event
    response = @hook.process_event(params[:event])

    # for cases like an invalid event, or when conversation does not have enough messages
    # for a label suggestion, the response is nil
    if response.nil?
      success_response(
        data: { message: nil },
        message: 'Event processed'
      )
    elsif response[:error]
      error_response(
        code: ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        message: response[:error]
      )
    else
      success_response(
        data: { message: response[:message] },
        message: 'Event processed successfully'
      )
    end
  end

  def destroy
    @hook.destroy!
    
    success_response(
      data: nil,
      message: 'Integration hook deleted successfully'
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    error_response(
      code: ApiErrorCodes::CANNOT_DELETE_RESOURCE,
      message: e.message
    )
  end

  private

  def fetch_hook
    @hook = Integrations::Hook.find(params[:id])
  end


  def permitted_params
    params.require(:hook).permit(:app_id, :inbox_id, :status, settings: {})
  end
end
