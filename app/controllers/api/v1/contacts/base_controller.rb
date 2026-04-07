class Api::V1::Contacts::BaseController < Api::V1::BaseController
  before_action :ensure_contact

  private

  def ensure_contact
    @contact = Contact.find(params[:contact_id])
  end
end
