class Api::V1::EvolutionGo::PrivacyController < Api::V1::BaseController
  before_action :set_instance_params, only: [:show, :update]

  # GET PRIVACY - GET /user/privacy
  def show
    Rails.logger.info "Evolution Go API: Getting privacy settings for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token'
      }, status: :bad_request
    end

    begin
      privacy_data = get_privacy_settings(@api_url, @instance_token)

      render json: {
        success: true,
        message: 'Privacy settings retrieved successfully',
        data: privacy_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Get privacy error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  # UPDATE PRIVACY - POST /user/privacy
  def update
    Rails.logger.info "Evolution Go API: Updating privacy settings for instance #{@instance_uuid}"

    if @api_url.blank? || @instance_token.blank?
      return render json: {
        error: 'Missing required parameters: api_url, instance_token'
      }, status: :bad_request
    end

    begin
      privacy_data = update_privacy_settings(@api_url, @instance_token, params[:privacy])

      render json: {
        success: true,
        message: 'Privacy settings updated successfully',
        data: privacy_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution Go API: Update privacy error: #{e.message}"
      render json: {
        error: e.message
      }, status: :unprocessable_entity
    end
  end

  private

  def set_instance_params
    # Primeiro tenta pegar o instance_uuid da URL (params[:id])
    @instance_uuid = params[:id] || params[:instance_uuid] || params[:instanceId]

    # Se instance_uuid não está na URL, busca nos privacy ou params
    if @instance_uuid.blank?
      privacy_params = params[:privacy] || params
      @instance_uuid = privacy_params[:instance_uuid] || privacy_params[:instanceId]
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
      privacy_params = params[:privacy] || params
      @api_url = privacy_params[:api_url]
      @admin_token = privacy_params[:admin_token]
      @instance_token = privacy_params[:instance_token]
    end
  end

  def get_privacy_settings(api_url, instance_token)
    privacy_url = "#{api_url.chomp('/')}/user/privacy"
    Rails.logger.info "Evolution Go API: Getting privacy settings at #{privacy_url}"
    Rails.logger.info "Evolution Go API: Using instance_token: #{instance_token ? '[PRESENT]' : '[MISSING]'}"

    uri = URI.parse(privacy_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = instance_token # header com apikey da instância
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Get privacy response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Get privacy response body: #{response.body}"

    raise "Failed to get privacy settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    # Evolution Go retorna direto o objeto de privacy, não wrapped em 'data'
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Get privacy JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API get privacy endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Get privacy connection error: #{e.class} - #{e.message}"
    raise "Failed to get privacy settings: #{e.message}"
  end

  def update_privacy_settings(api_url, instance_token, privacy)
    privacy_url = "#{api_url.chomp('/')}/user/privacy"
    Rails.logger.info "Evolution Go API: Updating privacy settings at #{privacy_url}"

    # Configurações de privacidade do Evolution Go
    request_body = {
      groupAdd: get_privacy_value(privacy, :groupAdd, 'groupAdd', 'all'),
      lastSeen: get_privacy_value(privacy, :lastSeen, 'lastSeen', 'all'),
      status: get_privacy_value(privacy, :status, 'status', 'all'),
      profile: get_privacy_value(privacy, :profile, 'profile', 'all'),
      readReceipts: get_privacy_value(privacy, :readReceipts, 'readReceipts', 'all'),
      callAdd: get_privacy_value(privacy, :callAdd, 'callAdd', 'all'),
      online: get_privacy_value(privacy, :online, 'online', 'all')
    }

    uri = URI.parse(privacy_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri)
    request['apikey'] = instance_token # header com apikey da instância
    request['Content-Type'] = 'application/json'
    request.body = request_body.to_json

    Rails.logger.info "Evolution Go API: Update privacy request body: #{request.body}"

    response = http.request(request)
    Rails.logger.info "Evolution Go API: Update privacy response code: #{response.code}"
    Rails.logger.info "Evolution Go API: Update privacy response body: #{response.body}"

    raise "Failed to update privacy settings. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    # Evolution Go retorna direto o objeto, não wrapped em 'data'
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution Go API: Update privacy JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution Go API update privacy endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Update privacy connection error: #{e.class} - #{e.message}"
    raise "Failed to update privacy settings: #{e.message}"
  end

  def get_privacy_value(privacy, symbol_key, string_key, default_value)
    return privacy[symbol_key] if privacy&.key?(symbol_key)
    return privacy[string_key] if privacy&.key?(string_key)

    default_value
  end
end
