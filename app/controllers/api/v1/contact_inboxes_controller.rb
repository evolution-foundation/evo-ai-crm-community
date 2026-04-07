class Api::V1::ContactInboxesController < Api::V1::BaseController
  before_action :ensure_inbox

  def filter
    contact_inbox = @inbox.contact_inboxes.find_by(source_id: permitted_params[:source_id])
    
    if contact_inbox.blank?
      error_response(
        code: ApiErrorCodes::RESOURCE_NOT_FOUND,
        message: 'Contact inbox not found'
      )
      return
    end

    @contact = contact_inbox.contact
    
    success_response(
      data: ContactSerializer.serialize(@contact),
      message: 'Contact retrieved successfully'
    )
  end

  private

  def ensure_inbox
    @inbox = Inbox.find(permitted_params[:inbox_id])
    authorize @inbox, :show?
  end

  def permitted_params
    params.permit(:inbox_id, :source_id)
  end
end
