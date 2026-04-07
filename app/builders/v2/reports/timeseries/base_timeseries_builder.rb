class V2::Reports::Timeseries::BaseTimeseriesBuilder
  include TimezoneHelper
  include DateRangeHelper
  DEFAULT_GROUP_BY = 'day'.freeze

  pattr_initialize :account, :params

  def scope
    case params[:type].to_sym
    when :account
      self
    when :inbox
      inbox
    when :agent
      user
    when :label
      label
    when :team
      team
    end
  end

  def inbox
    @inbox ||= Inbox.find(params[:id])
  end

  def user
    @user ||= User.find(params[:id])
  end

  def label
    @label ||= Label.find(params[:id])
  end

  def team
    @team ||= Team.find(params[:id])
  end

  # Proxy methods for when scope is self (account-level)
  def conversations
    Conversation.all
  end

  def messages
    Message.all
  end

  def reporting_events
    ReportingEvent.all
  end

  def group_by
    @group_by ||= %w[day week month year hour].include?(params[:group_by]) ? params[:group_by] : DEFAULT_GROUP_BY
  end

  def timezone
    @timezone ||= timezone_name_from_offset(params[:timezone_offset])
  end
end
