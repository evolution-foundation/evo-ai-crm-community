# frozen_string_literal: true

class Public::Api::V1::BaseController < PublicController
  before_action :authenticate_with_api_key!

  private

  def authenticate_with_api_key!
    # Accept both X-API-Key and api_access_token headers for flexibility
    # Rails converts HTTP headers: api_access_token -> HTTP_API_ACCESS_TOKEN
    api_key = request.headers['X-API-Key'] ||
              request.headers['api_access_token'] ||
              request.headers['HTTP_API_ACCESS_TOKEN'] ||
              request.headers[:api_access_token] ||
              request.headers[:HTTP_API_ACCESS_TOKEN]

    if api_key.blank?
      render_unauthorized('API key is missing')
      return
    end

    @access_token = AccessToken.for_token(api_key)

    if @access_token.blank?
      render_unauthorized('Invalid API key')
      return
    end

    # Set api_access_token for event listeners (EvoCampaign, Hooks, etc.)
    # This allows listeners to track the source of the lead creation
    Current.api_access_token = api_key

    Rails.logger.info "Public API: Authenticated with API key (owner: #{@access_token.owner_type})"
    Rails.logger.info "Public API: api_access_token set for event listeners"
  end

  def render_unauthorized(message = 'Unauthorized')
    render json: {
      success: false,
      error: message
    }, status: :unauthorized
  end

  def render_unprocessable_entity(errors)
    error_message = errors.is_a?(Array) ? errors.join(', ') : errors.to_s

    render json: {
      success: false,
      error: error_message,
      details: errors.is_a?(Array) ? errors : [errors]
    }, status: :unprocessable_entity
  end

  def render_not_found(message = 'Resource not found')
    render json: {
      success: false,
      error: message
    }, status: :not_found
  end
end

