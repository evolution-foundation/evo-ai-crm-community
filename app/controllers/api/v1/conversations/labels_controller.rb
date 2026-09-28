class Api::V1::Conversations::LabelsController < Api::V1::Conversations::BaseController
  include LabelConcern

  require_permissions({
    index: 'conversations.read',
    create: 'conversations.update',
    add: 'conversations.update',
    remove: 'conversations.update'
  })

  private

  def model
    @model ||= @conversation
  end

  def permitted_params
    params.permit(:conversation_id, labels: [])
  end
end
