module WahaConcern
  extend ActiveSupport::Concern

  private

  def waha_webhook_url
    backend_url = ENV['BACKEND_URL'].presence || GlobalConfigService.load('BACKEND_URL', nil).to_s.strip.presence
    raise 'BACKEND_URL is not configured (required to register WAHA webhook callback)' if backend_url.blank?

    "#{backend_url.chomp('/')}/webhooks/whatsapp/waha"
  end

  # webhook_hmac_key is registered with WAHA as this session webhook's HMAC
  # signing secret (config.webhooks[].hmac.key) so Webhooks::WhatsappController
  # can verify inbound payloads are genuinely from this WAHA instance/session
  # instead of trusting an unauthenticated POST to a guessable session name.
  def create_waha_session(base_url, api_key, session_name, webhook_hmac_key)
    HTTParty.post(
      "#{base_url.chomp('/')}/api/sessions",
      headers: { 'X-Api-Key' => api_key, 'Content-Type' => 'application/json' },
      body: {
        name: session_name,
        start: true,
        config: {
          webhooks: [{
            url: waha_webhook_url,
            events: ['message', 'session.status'],
            hmac: { key: webhook_hmac_key }
          }]
        }
      }.to_json,
      timeout: 30
    )
  end

  # Shared before_action target: both the authorizations#logout and the
  # qrcodes#show actions are addressed by inbox id (params[:id]) and need the
  # underlying Channel::Whatsapp to read provider_config / call provider_service.
  def set_channel
    inbox = ::Inbox.find(params[:id])
    @channel = inbox.channel
  end
end
