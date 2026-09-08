module EvoAuthConcern
  extend ActiveSupport::Concern

  private

  # Per-request memo on top of EvoAuth::IdentityResolver (shared with the cable).
  def authenticate_user_with_evo_auth(token, token_type)
    Current.evo_auth_validation_cache ||= {}
    cache_key = EvoAuth::IdentityResolver.cache_key(token, token_type)
    user_data = Current.evo_auth_validation_cache[cache_key]
    user_data ||= EvoAuth::IdentityResolver.new(token: token, token_type: token_type, auth_service: EvoAuthService.new).user_data

    Current.evo_auth_validation_cache[cache_key] = user_data

    set_current_user_from_auth_data(user_data, token, token_type)
    true
  rescue EvoAuthService::ValidationError => e
    Rails.logger.warn "EvoAuth: Token validation failed: #{e.message}"
    error_code = e.code.presence || ApiErrorCodes::UNAUTHORIZED
    error_status = e.status.presence || :unauthorized
    error_response(error_code, e.message, status: error_status)
    false
  rescue EvoAuthService::AuthenticationError => e
    Rails.logger.error "EvoAuth: Authentication service error: #{e.message}"
    error_response(ApiErrorCodes::SERVICE_UNAVAILABLE, 'Authentication service unavailable', status: :service_unavailable)
    false
  end

  def bearer_token_present?
    request.headers['Authorization']&.start_with?('Bearer ')
  end

  def set_current_user_from_auth_data(user_data, token, token_type)
    user = find_local_user(user_data['user'])
    raise EvoAuthService::ValidationError, 'User not found locally' unless user

    # Set current user
    Current.user = user
    @current_user = user
    Current.authentication_method = token_type

    # Store role key from evo-auth for permission checks
    role_key = user_data.dig('user', 'role', 'key') || user_data.dig('role', 'key')
    Current.evo_role_key = role_key

    # Resolve the granular `conversations.read_all` permission once per request and
    # cache it in Current. Admin short-circuits BEFORE any remote call. Non-admins
    # resolve via the remote evo-auth check (cached per request by the concern). The
    # model/policy/finder read this flag (mirroring how `administrator?` reads
    # `Current.evo_role_key`) — they never call the CRM `User#has_permission?` stub.
    Current.evo_can_read_all_inboxes =
      if user.administrator?
        true
      else
        has_user_permission?(user.id, 'conversations.read_all')
      end

    Current.account ||= RuntimeConfig.account

    # Store tokens for downstream services
    if token_type == 'bearer'
      Current.bearer_token = token
    elsif token_type == 'api_access_token'
      Current.api_access_token = token
    end
  end

  def find_local_user(user_data)
    EvoAuth::IdentityResolver.find_local_user(user_data)
  end

  # Override current_user method to return our authenticated user
  def current_user
    @current_user || Current.user
  end
end
