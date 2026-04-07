class Api::V1::BulkActionsController < Api::V1::BaseController
  before_action :type_matches?

  def create
    if type_matches?
      ::BulkActionsJob.perform_now(
        user: current_user,
        params: permitted_params
      )
      
      success_response(
        data: nil,
        message: 'Bulk action completed successfully',
        status: :created
      )
    else
      error_response(
        code: ApiErrorCodes::INVALID_PARAMETER,
        message: 'Invalid type. Must be Conversation or Contact'
      )
    end
  end

  private

  def type_matches?
    ['Conversation', 'Contact'].include?(params[:type])
  end

  def permitted_params
    params.permit(:type, :snoozed_until, ids: [], fields: [:status, :assignee_id, :team_id, :action], labels: [add: [], remove: []])
  end
end
