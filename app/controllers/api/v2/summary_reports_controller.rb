class Api::V2::SummaryReportsController < Api::V1::BaseController
  require_permissions({
    index: 'summary_reports.read',
    show: 'summary_reports.read',
    create: 'summary_reports.create',
    update: 'summary_reports.update',
    destroy: 'summary_reports.delete'
  })
  
  before_action :prepare_builder_params, only: [:agent, :team, :inbox]

  def agent
    render_report_with(V2::Reports::AgentSummaryBuilder)
  end

  def team
    render_report_with(V2::Reports::TeamSummaryBuilder)
  end

  def inbox
    render_report_with(V2::Reports::InboxSummaryBuilder)
  end

  private


  def prepare_builder_params
    @builder_params = {
      since: permitted_params[:since],
      until: permitted_params[:until],
      business_hours: ActiveModel::Type::Boolean.new.cast(permitted_params[:business_hours])
    }
  end

  def render_report_with(builder_class)
    builder = builder_class.new(account: nil, params: @builder_params)
    render json: builder.build
  end

  def permitted_params
    params.permit(:since, :until, :business_hours)
  end
end
