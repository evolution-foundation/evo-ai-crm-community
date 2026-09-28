class Api::V1::Contacts::LabelsController < Api::V1::Contacts::BaseController
  include LabelConcern

  require_permissions({
    index: 'contacts.read',
    create: 'contacts.update',
    add: 'contacts.update',
    remove: 'contacts.update'
  })

  private

  def model
    @model ||= @contact
  end

  def permitted_params
    params.permit(labels: [])
  end
end
