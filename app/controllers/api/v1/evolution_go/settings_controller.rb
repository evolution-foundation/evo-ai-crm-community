class Api::V1::EvolutionGo::SettingsController < Api::V1::BaseController
  before_action :set_instance_params, only: [:show, :update]

  # GET SETTINGS - GET /instance/:instanceId/advanced-settings
  def show
    Rails.logger.info "Evolution Go API: Getting advanced settings for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank? || @instance_uuid.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token, instance_uuid'
      }, status: :bad_request
    end

    begin
      settings_data = get_advanced_settings(@api_url, @instance_token, @instance_uuid)

      render json: {
        success: true,
        message: 'Advanced settings retrieved successfully',
        data: settings_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Get settings error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # UPDATE SETTINGS - PUT /instance/:instanceId/advanced-settings
  def update
    Rails.logger.info "Evolution Go API: Updating advanced settings for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank? || @instance_uuid.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token, instance_uuid'
      }, status: :bad_request
    end

    begin
      settings_data = update_advanced_settings(@api_url, @instance_token, @instance_uuid, params[:settings])

      render json: {
        success: true,
        message: 'Advanced settings updated successfully',
        data: settings_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Update settings error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  private

  def set_instance_params
    # Primeiro tenta pegar o instance_uuid da URL (params[:id])
    @instance_uuid = params[:id] || params[:instance_uuid] || params[:instanceId]

    # Se instance_uuid não está na URL, busca nos settings ou params
    if @instance_uuid.blank?
      settings_params = params[:settings] || params
      @instance_uuid = settings_params[:instance_uuid] || settings_params[:instanceId]
    end

    # Busca diretamente pelo Channel::Whatsapp para evitar problemas com associação polimórfica
    whatsapp_channel = Channel::Whatsapp.joins(:inbox)
                                        .where(provider: 'evolution_go')
                                        .where('provider_config @> ?', { instance_uuid: @instance_uuid }.to_json)
                                        .first

    if whatsapp_channel
      @inbox = whatsapp_channel.inbox
      @api_url = whatsapp_channel.provider_config['api_url']
      @admin_token = whatsapp_channel.provider_config['admin_token']
      @instance_token = whatsapp_channel.provider_config['instance_token']
    else
      # Fallback para parâmetros diretos (para compatibilidade)
      settings_params = params[:settings] || params
      @api_url = settings_params[:api_url]
      @admin_token = settings_params[:admin_token]
      @instance_token = settings_params[:instance_token]
    end
  end

  def get_advanced_settings(api_url, instance_token, instance_uuid)
    settings_url = "#{api_url.chomp('/')}/instance/#{instance_uuid}/advanced-settings"
    Rails.logger.info "Evolution Go API: Getting advanced settings at #{settings_url}"
    Rails.logger.info "Evolution Go API: Using instance_token: #{instance_token ? '[PRESENT]' : '[MISSING]'}"
    Rails.logger.info "Evolution Go API: Token length: #{instance_token&.length || 0}"

    uri = URI.parse(settings_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = instance_token # header com apikey da instância
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Get settings response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Get settings response body: #{response.body}"

    raise "Failed to get advanced settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    # Evolution Go retorna direto o objeto de settings, não wrapped em 'data'
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Get settings JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API get settings endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Get settings connection error: #{e.class} - #{e.message}"
    raise "Failed to get advanced settings: #{e.message}"
  end

  def update_advanced_settings(api_url, instance_token, instance_uuid, settings)
    settings_url = "#{api_url.chomp('/')}/instance/#{instance_uuid}/advanced-settings"
    Rails.logger.info "Evolution Go API: Updating advanced settings at #{settings_url}"

    # Configurações padrão do Evolution Go
    request_body = {
      alwaysOnline: get_setting_value(settings, :alwaysOnline, 'alwaysOnline', true),
      rejectCall: get_setting_value(settings, :rejectCall, 'rejectCall', true),
      readMessages: get_setting_value(settings, :readMessages, 'readMessages', true),
      ignoreGroups: get_setting_value(settings, :ignoreGroups, 'ignoreGroups', false),
      ignoreStatus: get_setting_value(settings, :ignoreStatus, 'ignoreStatus', true)
    }

    uri = URI.parse(settings_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Put.new(uri)
    request['apikey'] = instance_token # header com apikey da instância
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution Go API: Update settings request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Update settings response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Update settings response body: #{response.body}"

    raise "Failed to update advanced settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    # Evolution Go retorna direto o objeto, não wrapped em 'data'
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Update settings JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API update settings endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Update settings connection error: #{e.class} - #{e.message}"
    raise "Failed to update advanced settings: #{e.message}"
  end

  def get_setting_value(settings, symbol_key, string_key, default_value)
    return settings[symbol_key] if settings.key?(symbol_key)
    return settings[string_key] if settings.key?(string_key)

    default_value
  end
end
