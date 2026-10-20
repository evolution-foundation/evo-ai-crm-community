# frozen_string_literal: true

class Api::V1::DealConversationsController < Api::V1::BaseController
  before_action :set_deal
  before_action :authorize_deal

  def index
    success_response(data: DealSerializer.serialize(@deal)[:conversations])
  end

  def create
    @deal.attach_conversation!(Conversation.find(params[:conversation_id]))
    success_response(data: DealSerializer.serialize(@deal.reload), message: 'Conversation associated successfully', status: :created)
  end

  def destroy
    @deal.detach_conversation!(Conversation.find(params[:id]))
    success_response(data: DealSerializer.serialize(@deal.reload), message: 'Conversation removed successfully')
  end

  private

  def set_deal
    @deal = PipelineItem.find(params[:deal_id])
  end

  def authorize_deal
    authorize @deal.pipeline, action_name == 'index' ? :view? : :update? unless service_authenticated?
  end
end
