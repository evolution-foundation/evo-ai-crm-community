# frozen_string_literal: true

# Validates the X-Hub-Signature-256 header Meta adds to every webhook it posts:
# "sha256=" + the HMAC-SHA256 of the raw body, keyed with the app secret of the
# app that owns the subscription.
#
# A channel can sit behind more than one Meta app, so a controller lists every
# secret it accepts in `meta_app_secret_keys`; a signature made with any of the
# configured ones is valid. With none configured the request is refused: an
# unset secret must never match, and an HMAC with an empty key is computable by
# anyone. Every refusal answers the same 401, so the response says nothing about
# which part failed.
module MetaWebhookSignatureConcern
  extend ActiveSupport::Concern

  SIGNATURE_HEADER = 'X-Hub-Signature-256'
  SIGNATURE_PREFIX = 'sha256='

  private

  def verify_meta_signature!
    secrets = meta_app_secrets
    return refuse_meta_signature('no app secret configured') if secrets.empty?

    provided = request.headers[SIGNATURE_HEADER].to_s
    return refuse_meta_signature('missing or malformed signature header') unless provided.start_with?(SIGNATURE_PREFIX)

    body = request.raw_post
    # `map` before `any?` on purpose: every configured secret is tried, so the time spent
    # does not say which one matched. Short-circuiting here would put that back.
    valid = secrets.map { |secret| meta_signature_matches?(secret, body, provided) }.any?
    refuse_meta_signature('signature mismatch') unless valid
  end

  def meta_app_secret_keys
    raise NotImplementedError, "#{self.class} must define meta_app_secret_keys"
  end

  def meta_app_secrets
    meta_app_secret_keys.filter_map { |key| GlobalConfigService.load(key, nil).to_s.presence }
  end

  def meta_signature_matches?(secret, body, provided)
    expected = "#{SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, body)}"
    ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end

  def refuse_meta_signature(reason)
    Rails.logger.warn("#{self.class.name}: webhook refused — #{reason}, body_size=#{request.raw_post.bytesize}")
    render json: { error: 'Invalid signature' }, status: :unauthorized
  end
end
