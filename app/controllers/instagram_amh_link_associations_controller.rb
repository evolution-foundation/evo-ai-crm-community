# frozen_string_literal: true

# Same service authentication, replay protection and rate limit as resolution.
class InstagramAmhLinkAssociationsController < InstagramAmhLinkResolutionsController
  def create
    response.headers.merge!('Cache-Control' => 'private, no-store', 'X-Robots-Tag' => 'noindex, nofollow',
                            'Referrer-Policy' => 'no-referrer')
    return head :not_found unless ENV['INSTAGRAM_AMH_ASSOCIATION_QA_ENABLED'] == 'true' && ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] == 'true'
    return head :unauthorized unless authenticated?

    payload = signed_payload
    return head :bad_request unless payload
    return head :too_many_requests unless rate_allowed?(payload['rate_key'])

    render json: { assertion: Instagram::AmhRegistrationBinding.issue!(payload) }
  rescue Instagram::AmhConnection::ConfigurationError, Instagram::AmhShortLink::Unavailable,
         ActiveRecord::RecordNotFound, ActiveSupport::MessageEncryptor::InvalidMessage
    render json: { error: 'Contexto indisponível' }, status: :not_found
  rescue Redis::BaseError, ConnectionPool::TimeoutError
    head :service_unavailable
  end

  private

  def signed_payload
    value = JSON.parse(request.raw_post)
    fields = %w[attribution_id email_hash graph_digest material rate_key request_id version_id]
    value if value.is_a?(Hash) && value.keys.sort == fields
  rescue JSON::ParserError
    nil
  end
end
