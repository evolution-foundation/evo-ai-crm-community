class Webhooks::InstagramController < ActionController::API
  include MetaTokenVerifyConcern
  include MetaWebhookSignatureConcern

  # Every key of an entry that Meta fills with a list of objects. A signed body is still
  # a body off the wire, so each one is checked before the job reads it.
  EVENT_KEYS = %i[messaging standby changes].freeze

  before_action :verify_meta_signature!, only: :events

  def events
    Rails.logger.info('Instagram webhook received events')

    entries = params.to_unsafe_hash[:entry]
    return refuse_envelope unless instagram_object? && valid_entries?(entries)

    Rails.logger.info("Instagram webhook entry count: #{entries.length}")
    ::Webhooks::InstagramEventsJob.perform_later(entries)
    render json: :ok
  end

  private

  def meta_app_secret_keys
    # INSTAGRAM_APP_SECRET is the app of direct Instagram login; FB_APP_SECRET the app of the
    # Facebook page the Instagram account is linked to. Meta signs with the one that owns the webhook.
    %w[INSTAGRAM_APP_SECRET FB_APP_SECRET]
  end

  def valid_entries?(entries)
    entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) && EVENT_KEYS.all? { |key| valid_events?(entry[key]) } }
  end

  def instagram_object?
    params['object'].to_s.casecmp('instagram').zero?
  end

  def refuse_envelope
    Rails.logger.warn("Instagram webhook refused: unexpected envelope (object=#{params['object'].to_s[0, 40].inspect})")
    head :unprocessable_entity
  end

  def valid_events?(events)
    events.nil? || (events.is_a?(Array) && events.all?(Hash))
  end

  def valid_token?(token)
    # Both configs default to '', so a blank token would match an unconfigured channel.
    return false if token.blank?

    # IG_VERIFY_TOKEN is the Instagram channel via a Facebook page;
    # INSTAGRAM_VERIFY_TOKEN is the channel via direct Instagram login.
    token == GlobalConfigService.load('IG_VERIFY_TOKEN', '') ||
      token == GlobalConfigService.load('INSTAGRAM_VERIFY_TOKEN', '')
  end
end
