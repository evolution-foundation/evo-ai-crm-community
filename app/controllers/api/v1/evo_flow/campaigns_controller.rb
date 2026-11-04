class Api::V1::EvoFlow::CampaignsController < Api::V1::BaseController
  include EvoFlowProxy

  PERMISSION_KEYS = %w[
    campaigns.read campaigns.create campaigns.update campaigns.delete
    campaigns.schedule campaigns.execute campaigns.pause campaigns.resume campaigns.stop
    campaigns.duplicate campaigns.bulk_action
  ].freeze
  PERMISSION_KEYS.each { |key| EvoPermissionConcern.register_permission_key(key) }

  # POST /campaigns/:id/<action>, /campaigns/:id/execution/cancel and
  # /campaigns/bulk-action, by last segment.
  ACTION_PERMISSIONS = {
    'schedule' => 'campaigns.schedule',
    'execute' => 'campaigns.execute',
    'pause' => 'campaigns.pause',
    'resume' => 'campaigns.resume',
    'stop' => 'campaigns.stop',
    'cancel' => 'campaigns.stop',
    'duplicate' => 'campaigns.duplicate',
    'bulk-action' => 'campaigns.bulk_action'
  }.freeze

  # A bulk action also demands the key of the action it applies, by body `action`.
  BULK_ACTION_PERMISSIONS = {
    'pause' => 'campaigns.pause',
    'resume' => 'campaigns.resume',
    'delete' => 'campaigns.delete',
    'duplicate' => 'campaigns.duplicate'
  }.freeze

  private

  def evo_flow_resource
    'campaigns'
  end

  def check_proxy_permission!
    super
    return if performed? || !bulk_action_request?

    action = request.request_parameters['action'].to_s.downcase
    check_permission!(BULK_ACTION_PERMISSIONS.fetch(action, 'campaigns.update'), :user)
  end

  def bulk_action_request?
    request.request_method_symbol == :post && params[:path].to_s.downcase == 'bulk-action'
  end

  def required_permission_key
    sub = params[:path].to_s.downcase

    case request.request_method_symbol
    when :get, :head then 'campaigns.read'
    when :delete     then 'campaigns.delete'
    when :post       then sub.empty? ? 'campaigns.create' : ACTION_PERMISSIONS.fetch(sub.split('/').last, 'campaigns.update')
    else 'campaigns.update'
    end
  end
end
