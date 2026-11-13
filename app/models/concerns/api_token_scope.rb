# frozen_string_literal: true

# A request authenticated by an API access token is bounded by the token's
# scopes (Current.api_token_scopes, from the auth validation). Only checks about
# the authenticated user are bounded; nil scopes mean no bound (sessions,
# "default" tokens, service tokens).
module ApiTokenScope
  module_function

  def narrows?(user_id)
    !Current.api_token_scopes.nil? &&
      Current.authentication_method == 'api_access_token' &&
      user_id.present? && user_id.to_s == Current.user&.id.to_s
  end

  def allows?(user_id, permission)
    !narrows?(user_id) || Current.api_token_scopes.include?(permission)
  end
end
