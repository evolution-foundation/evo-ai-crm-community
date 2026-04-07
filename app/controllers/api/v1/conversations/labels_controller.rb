class Api::V1::Conversations::LabelsController < Api::V1::Conversations::BaseController
  include LabelConcern

  private

  def model
    @model ||= @conversation
  end

  def permitted_params
    params.permit(:conversation_id, labels: [])
  end
end
