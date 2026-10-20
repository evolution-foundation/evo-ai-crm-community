# frozen_string_literal: true

class Api::V1::DealHistoryController < Api::V1::BaseController
  before_action :set_deal

  def index
    authorize @deal.pipeline, :view? unless service_authenticated?
    success_response(data: DealSerializer.serialize(@deal)[:history], message: 'Deal history retrieved successfully')
  end

  private

  def set_deal
    @deal = PipelineItem.find(params[:deal_id])
  end
end
