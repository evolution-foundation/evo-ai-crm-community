# frozen_string_literal: true

# Dedicated service-only endpoint: HMAC does not grant any CRM user privileges.
class InstagramAmhLinkResolutionsController < ActionController::API
  def create
    response.headers.merge!('Cache-Control' => 'private, no-store', 'X-Robots-Tag' => 'noindex, nofollow',
                            'Referrer-Policy' => 'no-referrer')
    return head :not_found unless ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] == 'true'
    return head :unauthorized unless authenticated?
    return head :too_many_requests unless rate_allowed?

    render json: Instagram::AmhShortLink.resolve(params[:code])
  rescue Instagram::AmhShortLink::Unavailable
    render json: { error: 'Link indisponível' }, status: :not_found
  rescue Redis::BaseError
    head :service_unavailable # Fail closed if replay/rate-limit storage is unavailable.
  end

  private

  def authenticated?
    secret = ENV['INSTAGRAM_AMH_LINK_SERVICE_SECRET'].to_s
    timestamp = request.headers['X-Amh-Timestamp'].to_s
    nonce = request.headers['X-Amh-Nonce'].to_s
    signature = request.headers['X-Amh-Signature'].to_s
    return false unless valid_headers?(secret, timestamp, nonce, signature)

    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{nonce}.#{request.raw_post}")
    return false unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)

    $velma.set("amh-link-nonce:#{nonce}", '1', nx: true, ex: 120).present? # rubocop:disable Style/GlobalVars
  end

  def valid_headers?(secret, timestamp, nonce, signature)
    return false unless secret.bytesize >= 32 && /\A\d{10}\z/.match?(timestamp)
    return false unless (Time.current.to_i - timestamp.to_i).abs <= 60 && request.raw_post.bytesize <= 1024

    /\A[0-9a-f]{32}\z/.match?(nonce) && /\A[0-9a-f]{64}\z/.match?(signature)
  end

  def rate_allowed?
    key = params[:rate_key].to_s
    return false unless /\A[0-9a-f]{64}\z/.match?(key)

    # Atomic fixed window, shared by all CRM processes. Raw IP is never persisted.
    window = Time.current.to_i / 60
    script = "local n = redis.call('INCR', KEYS[1]); if n == 1 then redis.call('EXPIRE', KEYS[1], 120) end; return n"
    $velma.eval(script, keys: ["amh-link-rate:#{window}:#{key}"]).to_i <= 30 # rubocop:disable Style/GlobalVars
  end
end
