module EvolutionConcern
  extend ActiveSupport::Concern

  # Raised when Evolution API reports the instance doesn't exist (HTTP 404
  # from /instance/connect). Archiving a channel logs the instance out, and
  # Evolution API can end up deleting it server-side when the WhatsApp
  # session was already disconnected at that point (logout on a
  # non-connected session fails, and disconnect falls back to delete). A
  # dedicated error class lets callers recreate the instance and retry
  # instead of surfacing a dead end to the user.
  class InstanceNotFoundError < StandardError; end

  private

  # Resolve `api_url` for an Evolution channel, falling back to the global
  # admin config (EVOLUTION_API_URL) when the channel has an empty
  # `provider_config['api_url']` or when channel is nil (pre-creation flows).
  #
  # Accepts optional raw_params to check request params before GlobalConfig
  # (used in create actions where the channel may not exist yet).
  def evolution_api_url_for(channel, raw_params = {})
    url = channel&.provider_config&.dig('api_url').presence ||
          raw_params[:api_url].presence ||
          GlobalConfigService.load('EVOLUTION_API_URL', '').to_s.strip
    url.presence
  end

  def evolution_admin_token_for(channel, raw_params = {})
    token = channel&.provider_config&.dig('admin_token').presence ||
            raw_params[:api_hash].presence ||
            GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', '').to_s.strip
    token.presence
  end

  # Resolve credentials with GlobalConfig fallback. Works for both:
  # - Existing channels (reads provider_config, falls back to GlobalConfig)
  # - Pre-creation flows where channel is nil (reads raw_params, falls back to GlobalConfig)
  #
  # Raises with a clear message when credentials are missing from all sources.
  def evolution_credentials_for!(channel, raw_params = {})
    api_url = evolution_api_url_for(channel, raw_params)
    api_hash = evolution_admin_token_for(channel, raw_params)

    if api_url.blank? || api_hash.blank?
      raise StandardError,
            'Evolution API not configured. Set api_url + admin_token on the channel, ' \
            'provide them in the request, or configure EVOLUTION_API_URL + EVOLUTION_ADMIN_SECRET globally.'
    end

    [api_url, api_hash]
  end

  # Convenience alias for controllers that pass raw_params in create actions.
  def resolve_evolution_credentials(channel, raw_params)
    evolution_credentials_for!(channel, raw_params)
  end

  def evolution_webhook_url
    backend_url = ENV['BACKEND_URL'].to_s.strip
    raise 'BACKEND_URL is not configured (required to register Evolution webhook callback)' if backend_url.empty?

    "#{backend_url.chomp('/')}/webhooks/whatsapp/evolution"
  end

  # Creates (or recreates) an Evolution API instance with the given name,
  # wired to this app's webhook, exactly as done for a brand-new channel.
  # Shared between Evolution::AuthorizationsController#create (first-time
  # setup) and Evolution::QrcodesController (recreating an instance Evolution
  # deleted server-side — see InstanceNotFoundError).
  def create_evolution_instance!(api_url, admin_token, instance_name, phone_number)
    create_url = "#{api_url.chomp('/')}/instance/create"
    clean_number = phone_number.to_s.gsub(/[+\s-]/, '')

    request_body = {
      instanceName: instance_name,
      number: clean_number,
      integration: 'WHATSAPP-BAILEYS',
      qrcode: false,
      webhook: {
        url: evolution_webhook_url,
        byEvents: false,
        base64: true,
        events: %w[
          CONNECTION_UPDATE CONTACTS_SET CONTACTS_UPDATE CONTACTS_UPSERT
          LABELS_ASSOCIATION LABELS_EDIT LOGOUT_INSTANCE MESSAGES_DELETE
          MESSAGES_UPDATE MESSAGES_UPSERT SEND_MESSAGE
        ]
      }
    }

    uri = URI.parse(create_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = admin_token
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    response = http.request(request)
    Rails.logger.info "Evolution API: (Re)create instance #{instance_name} response code: #{response.code}"

    raise "Failed to create instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: Create instance JSON parse error: #{e.message}"
    raise 'Invalid response from Evolution API create instance endpoint'
  end
end
