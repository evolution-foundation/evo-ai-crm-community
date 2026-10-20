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
    return head :too_many_requests unless association_rate_allowed?(payload['rate_key'])

    render json: { assertion: Instagram::AmhRegistrationBinding.issue!(payload) }
  rescue Instagram::AmhConnection::ConfigurationError, Instagram::AmhShortLink::Unavailable,
         ActiveRecord::RecordNotFound, ActiveSupport::MessageEncryptor::InvalidMessage
    render json: { error: 'Contexto indisponível' }, status: :not_found
  rescue Redis::BaseError, ConnectionPool::TimeoutError, ActiveRecord::ConnectionNotEstablished,
         ActiveRecord::ConnectionTimeoutError, ActiveRecord::StatementInvalid
    head :service_unavailable
  end

  private

  def association_rate_allowed?(client_key)
    # One authenticated service credential in this QA contract. A caller cannot
    # rotate a submitted rate_key to escape this independent server-owned budget.
    rate_allowed?(Digest::SHA256.hexdigest('amh-association-service-v1')) && rate_allowed?(client_key)
  end

  def signed_payload
    value = JSON.parse(request.raw_post)
    fields = %w[attribution_id email_hash graph_digest material rate_key request_id version_id]
    value if value.is_a?(Hash) && value.keys.sort == fields
  rescue JSON::ParserError
    nil
  end
end
