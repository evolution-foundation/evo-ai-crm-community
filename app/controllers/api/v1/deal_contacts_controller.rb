# frozen_string_literal: true

class Api::V1::DealContactsController < Api::V1::BaseController
  before_action :set_deal
  before_action :authorize_deal

  def index
    success_response(data: @deal.contacts.map { |contact| ContactSerializer.serialize(contact, include_labels: true) })
  end

  def create
    contact = Contact.find(params[:contact_id])
    @deal.attach_contact!(contact)
    if ActiveModel::Type::Boolean.new.cast(params[:primary]) && contact.type == 'person'
      @deal.update!(primary_contact: contact, contact_id: contact.id)
    end
    success_response(data: DealSerializer.serialize(@deal.reload), message: 'Contact associated successfully', status: :created)
  end

  def destroy
    @deal.detach_contact!(Contact.find(params[:id]))
    success_response(data: DealSerializer.serialize(@deal.reload), message: 'Contact removed successfully')
  end

  private

  def set_deal
    @deal = PipelineItem.find(params[:deal_id])
  end

  def authorize_deal
    authorize @deal.pipeline, action_name == 'index' ? :view? : :update? unless service_authenticated?
  end
end
