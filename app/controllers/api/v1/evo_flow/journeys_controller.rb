class Api::V1::EvoFlow::JourneysController < Api::V1::BaseController
  include EvoFlowProxy

  PERMISSION_KEYS = %w[
    journeys.read journeys.create journeys.update journeys.delete
    journeys.toggle_active journeys.duplicate journeys.manage_sessions
  ].freeze
  PERMISSION_KEYS.each { |key| EvoPermissionConcern.register_permission_key(key) }

  private

  def evo_flow_resource
    'journeys'
  end

  # Subpath decides before the verb: evo-flow serves sessions under
  # GET/DELETE /journeys/:id/sessions*, so keying off the verb made
  # journeys.manage_sessions unreachable.
  def required_permission_key
    sub = params[:path].to_s.downcase

    return 'journeys.manage_sessions' if sub.include?('session')
    return 'journeys.toggle_active' if sub.include?('toggle-active')
    return 'journeys.duplicate' if sub.include?('duplicate')

    case request.request_method_symbol
    when :get, :head then 'journeys.read'
    when :delete     then 'journeys.delete'
    when :post       then sub.empty? ? 'journeys.create' : 'journeys.update'
    else 'journeys.update'
    end
  end
end
