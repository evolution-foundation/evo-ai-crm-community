class Api::V1::Contacts::LabelsController < Api::V1::Contacts::BaseController
  include LabelConcern

  private

  def model
    @model ||= @contact
  end

  def permitted_params
    params.permit(labels: [])
  end
end
