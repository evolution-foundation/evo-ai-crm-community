module EvolutionGoConcern
  extend ActiveSupport::Concern

  private

  def connect_instance(api_url, instance_token, _instance_name = nil)
    connect_url = "#{api_url.chomp('/')}/instance/connect"
    Rails.logger.info "Evolution Go API: Connecting instance at #{connect_url}"

    webhook_url_value = webhook_url

    request_body = {
      subscribe: [
        'MESSAGE',
        'READ_RECEIPT',
        'CONNECTION'
      ],
      webhookUrl: webhook_url_value
    }

    uri = URI.parse(connect_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution Go API: Connect instance request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Connect instance response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Connect instance response body: #{response.body}"

    raise "Failed to connect instance. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Connect instance JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API connect instance endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Connect instance connection error: #{e.class} - #{e.message}"
    raise "Failed to connect instance: #{e.message}"
  end

  def webhook_url
    backend_url = ENV['BACKEND_URL'].presence ||
                  GlobalConfigService.load('BACKEND_URL', 'https://api.evoai.app').to_s.strip
    "#{backend_url.chomp('/')}/webhooks/whatsapp/evolution_go"
  end

  # Resolves Evolution Go credentials for an existing channel, falling back to
  # the global Admin Settings (EVOLUTION_GO_API_URL / EVOLUTION_GO_ADMIN_SECRET)
  # when provider_config is missing values. Older channels created before the
  # provider_config persistence fix may have empty api_url/admin_token.
  #
  # When a channel is supplied but instance_token / instance_uuid are blank,
  # logs a warning so corrupt-channel cases are observable in production. The
  # action-level guards still respond with 400 — this is purely diagnostics.
  def evolution_go_credentials_for(whatsapp_channel)
    config = whatsapp_channel&.provider_config || {}

    creds = {
      api_url: config['api_url'].presence || GlobalConfigService.load('EVOLUTION_GO_API_URL', '').to_s.strip,
      admin_token: config['admin_token'].presence || GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '').to_s.strip,
      instance_token: config['instance_token'],
      instance_uuid: config['instance_uuid'],
      instance_name: config['instance_name']
    }

    if whatsapp_channel && (creds[:instance_token].blank? || creds[:instance_uuid].blank?)
      Rails.logger.warn(
        "Evolution Go API: channel #{whatsapp_channel.id} resolved with missing instance credentials " \
        '(instance_token/instance_uuid blank). Channel may need to be recreated.'
      )
    end

    creds
  end
end
