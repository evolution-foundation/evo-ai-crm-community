# frozen_string_literal: true

# Generic passthrough proxy to one evo-flow surface (/journeys*, /campaigns*):
# forwards method + subpath + query + body and returns evo-flow's response
# verbatim. The including controller names the surface (#evo_flow_resource) and
# maps each request to a permission key (#required_permission_key).
module EvoFlowProxy
  extend ActiveSupport::Concern

  MAX_BODY_BYTES = 300_000
  MAX_BODY_DEPTH = 25

  # Rails unescapes the glob (%2F -> /, %2e -> .) and Client#join runs URI.join,
  # which resolves dot segments: `..` leaves the surface for any evo-flow endpoint,
  # and `.` makes evo-flow serve a path other than the one the permission came from.
  SAFE_SUBPATH = %r{\A[A-Za-z0-9\-._~/]+\z}
  DOT_SEGMENTS = %w[. ..].freeze

  included do
    include EvoFlowTenantPassthrough

    # ParamsWrapper MERGES its wrapper into request.request_parameters — the hash
    # this proxy forwards.
    wrap_parameters false

    rescue_from EvoFlow::ConfigurationError, with: :handle_evo_flow_misconfiguration

    before_action :reject_unsafe_subpath!
    before_action :check_proxy_permission!
  end

  def proxy
    ef_path = build_path
    body = request_body

    return if body && !guard_body_payload(body)

    status, result =
      case request.request_method_symbol
      when :get, :head then client.request(:get, ef_path, query: request.query_parameters)
      when :post       then client.request(:post, ef_path, payload: body || {})
      when :put        then client.request(:put, ef_path, payload: body || {})
      when :patch      then client.request(:patch, ef_path, payload: body || {})
      when :delete     then client.request(:delete, ef_path)
      else return head(:method_not_allowed)
      end

    relay(status, result)
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  private

  def client
    @client ||= EvoFlow::Client.new(extra_headers: evo_flow_passthrough_headers)
  end

  # evo-flow's own status, not a guessed one: 201 on create AND duplicate, 204 on delete.
  def relay(status, result)
    return head(:no_content) if status == 204 || result.nil?

    render json: result, status: status
  end

  def reject_unsafe_subpath!
    sub = params[:path].to_s
    return if sub.blank?
    return if sub.match?(SAFE_SUBPATH) && sub.split('/').none? { |segment| DOT_SEGMENTS.include?(segment) }

    render json: { errors: { message: "Invalid #{evo_flow_resource} path" } }, status: :bad_request
  end

  # Name is load-bearing: spec/rbac/mutating_actions_gate_guard_spec reflects over
  # check_<action>_permission! to prove the route is gated.
  def check_proxy_permission!
    check_permission!(required_permission_key, :user)
  end

  def build_path
    sub = params[:path].to_s.sub(%r{\A/+}, '')
    sub.empty? ? "/#{evo_flow_resource}" : "/#{evo_flow_resource}/#{sub}"
  end

  # Deliberately not strong params: `permit` mangles nested flowData (drops
  # `nodes: []`). A bare array arrives as { "_json" => [...] } and
  # POST /journeys/:id/variables needs it unwrapped.
  def request_body
    return nil unless request.request_method_symbol.in?(%i[post put patch])

    rp = request.request_parameters
    rp = rp.to_unsafe_h if rp.respond_to?(:to_unsafe_h)
    rp.is_a?(Hash) && rp.keys == ['_json'] ? rp['_json'] : rp
  end

  def guard_body_payload(body)
    return true if body.to_json.bytesize <= MAX_BODY_BYTES && structure_depth(body) <= MAX_BODY_DEPTH

    render json: { errors: { message: "#{evo_flow_resource.singularize.capitalize} payload is too large or too deeply nested" } },
           status: :payload_too_large
    false
  end

  def structure_depth(obj)
    case obj
    when Hash
      obj.empty? ? 1 : 1 + obj.values.map { |v| structure_depth(v) }.max
    when Array
      obj.empty? ? 1 : 1 + obj.map { |v| structure_depth(v) }.max
    else
      0
    end
  end

  # evo-flow's 401 refuses the service call, not the user's session; relayed as-is,
  # the browser reads it as a lost session and logs out.
  def handle_evo_flow_error(error)
    body = error.response&.parsed_response || { message: error.message }
    status = error.code.nil? || error.code == 401 ? :bad_gateway : error.code
    render json: { errors: body }, status: status
  end

  # 503, not 500: the integration was never configured on this deployment.
  def handle_evo_flow_misconfiguration(error)
    Rails.logger.error("evo-flow integration is not configured: #{error.message}")
    error_response(
      ApiErrorCodes::SERVICE_UNAVAILABLE,
      "#{evo_flow_resource.capitalize} are unavailable: the evo-flow integration is not configured on this deployment",
      status: :service_unavailable
    )
  end
end
