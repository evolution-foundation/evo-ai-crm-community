# frozen_string_literal: true

class Api::V1::DashboardController < Api::V1::BaseController
  require_permissions({
    customer: 'dashboard.read'
  })

  def customer
    dashboard_data = Dashboard::CustomerDashboardService.new(
      params: dashboard_params
    ).call

    success_response(
      data: dashboard_data,
      message: 'Customer dashboard data retrieved successfully'
    )
  end

  private

  def dashboard_params
    params.permit(:pipeline_id, :team_id, :inbox_id, :user_id, :since, :until)
  end
end
