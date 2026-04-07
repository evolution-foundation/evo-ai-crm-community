# frozen_string_literal: true

class Api::V1::Zapi::QrcodesController < Api::V1::BaseController
  before_action :set_instance_params, only: [:show, :create, :refresh]

  def show
    Rails.logger.info "Z-API: Getting QR code for instance #{@instance_id}"

    begin
      if @token.blank? || @instance_id.blank?
        return render json: {
          error: 'Missing required parameters: token, instance_id'
        }, status: :bad_request
      end

      # Get QR code using Z-API
      qrcode_data = get_zapi_qrcode(@api_url, @instance_id, @token)

      # Update provider_connection status if we have connection info
      if @whatsapp_channel && qrcode_data.is_a?(Hash) && qrcode_data.key?(:connected)
        update_provider_connection_from_qrcode(@whatsapp_channel, qrcode_data)
      end

      render json: qrcode_data
    rescue StandardError => e
      Rails.logger.error "Z-API: QR code error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def create
    Rails.logger.info "Z-API: QR code refresh called with params: #{params.inspect}"

    begin
      # Extract parameters
      auth_params = params[:qrcode] || params
      api_url = auth_params[:api_url]
      instance_id = auth_params[:instance_id]
      token = auth_params[:token]

      if token.blank? || instance_id.blank?
        return render json: {
          error: 'Missing required parameters: token, instance_id'
        }, status: :bad_request
      end

      Rails.logger.info "Z-API: Getting QR code for instance #{instance_id}"

      # Get QR code using Z-API
      qrcode_data = get_zapi_qrcode(api_url, instance_id, token)

      render json: {
        success: true,
        qrcode: qrcode_data
      }
    rescue StandardError => e
      Rails.logger.error "Z-API: QR code error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def refresh
    Rails.logger.info "Z-API: QR code refresh called for instance #{@instance_id}"

    begin
      if @token.blank? || @instance_id.blank?
        return render json: {
          error: 'Missing required parameters: token, instance_id'
        }, status: :bad_request
      end

      # Get QR code using Z-API
      qrcode_data = get_zapi_qrcode(@api_url, @instance_id, @token)

      # Update provider_connection status if we have connection info
      if @whatsapp_channel && qrcode_data.is_a?(Hash) && qrcode_data.key?(:connected)
        update_provider_connection_from_qrcode(@whatsapp_channel, qrcode_data)
      end

      render json: qrcode_data
    rescue StandardError => e
      Rails.logger.error "Z-API: QR code refresh error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def status
    identifier = params[:instance_id] || params[:id]
    Rails.logger.info "Z-API: Getting status for instance #{identifier}"

    begin
      return render json: { error: 'Instance ID required' }, status: :bad_request if identifier.blank?

      whatsapp_channel = find_channel_by_instance_id(identifier)
      return render json: { error: 'Channel not found' }, status: :not_found unless whatsapp_channel

      api_url = 'https://api.z-api.io' # Z-API sempre usa a mesma URL base
      instance_id = whatsapp_channel.provider_config['instance_id']
      token = whatsapp_channel.provider_config['token']
      client_token = whatsapp_channel.provider_config['client_token']

      status_data = get_zapi_status(api_url, instance_id, token, client_token)

      # Update provider_connection status
      update_provider_connection_from_status(whatsapp_channel, status_data)

      render json: status_data
    rescue StandardError => e
      Rails.logger.error "Z-API: Status error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def set_instance_params
    # Para o método show, recebe instance_id da URL (params[:id])
    identifier = params[:id] || params[:instance_id]

    return if identifier.blank?

    Rails.logger.info "Z-API: Looking for instance with identifier: #{identifier}"

    @whatsapp_channel = find_channel_by_instance_id(identifier)

    return unless @whatsapp_channel

    Rails.logger.info "Z-API: Found channel with config: #{@whatsapp_channel.provider_config.inspect}"

    @inbox = @whatsapp_channel.inbox
    @api_url = 'https://api.z-api.io' # Z-API sempre usa a mesma URL base
    @instance_id = @whatsapp_channel.provider_config['instance_id']
    @token = @whatsapp_channel.provider_config['token']
    @client_token = @whatsapp_channel.provider_config['client_token']
  end

  def find_channel_by_instance_id(instance_id)
    Channel::Whatsapp.joins(:inbox)
                     .where(provider: 'zapi')
                     .where('provider_config @> ?', { instance_id: instance_id }.to_json)
                     .first
  end

  def get_zapi_qrcode(api_url, instance_id, token)
    # Z-API endpoint: GET /instances/{INSTANCE}/token/{TOKEN}/qr-code/image
    # Retorna base64 da imagem
    qrcode_url = "#{api_url.chomp('/')}/instances/#{instance_id}/token/#{token}/qr-code/image"
    Rails.logger.info "Z-API: Getting QR code from #{qrcode_url}"

    uri = URI.parse(qrcode_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    # Z-API requer Client-Token no header
    request['Client-Token'] = @client_token if @client_token.present?
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Z-API: QR code response code: #{response.code}"
    Rails.logger.info "Z-API: QR code response body: #{response.body[0..200]}"

    raise "Failed to get QR code. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed_response = JSON.parse(response.body)

    # Z-API retorna base64 diretamente ou em estrutura JSON
    # Formato esperado: { "value": "data:image/png;base64,..." } ou { "base64": "..." } ou string base64 direta
    base64_data = if parsed_response.is_a?(Hash)
                    parsed_response['value'] || parsed_response['base64'] || parsed_response['qrcode'] || parsed_response['data']
                  else
                    parsed_response
                  end

    # Se não tem base64, tentar pegar código de pareamento por telefone
    phone_code = nil
    if parsed_response.is_a?(Hash) && parsed_response['code'].blank?
      phone_code = get_phone_code(api_url, instance_id, token)
    end

    # Verificar status de conexão se client_token estiver disponível
    connected = false
    if @client_token.present?
      begin
        status_data = get_zapi_status(api_url, instance_id, token, @client_token)
        connected = status_data[:connected] || false
      rescue StandardError => e
        Rails.logger.warn "Z-API: Could not check connection status: #{e.message}"
      end
    end

    {
      base64: base64_data,
      code: phone_code || parsed_response['code'],
      connected: connected
    }
  rescue JSON::ParserError => e
    Rails.logger.error "Z-API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Z-API QR code endpoint'
  rescue StandardError => e
    Rails.logger.error "Z-API: QR code connection error: #{e.class} - #{e.message}"
    raise "Failed to get QR code: #{e.message}"
  end

  def get_phone_code(api_url, instance_id, token)
    # Z-API endpoint para código de pareamento por telefone
    # GET /instances/{INSTANCE}/token/{TOKEN}/phone-code/{phone}
    # Mas precisamos do número de telefone, então vamos retornar nil por enquanto
    # O frontend pode solicitar isso separadamente se necessário
    nil
  end

  def get_zapi_status(api_url, instance_id, token, client_token)
    # Z-API endpoint: GET /instances/{INSTANCE}/token/{TOKEN}/status
    status_url = "#{api_url.chomp('/')}/instances/#{instance_id}/token/#{token}/status"
    Rails.logger.info "Z-API: Getting status from #{status_url}"

    uri = URI.parse(status_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    # Z-API requer Client-Token no header
    request['Client-Token'] = client_token if client_token.present?
    request['Content-Type'] = 'application/json'

    response = http.request(request)
    Rails.logger.info "Z-API: Status response code: #{response.code}"
    Rails.logger.info "Z-API: Status response body: #{response.body}"

    raise "Failed to get status. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed_response = JSON.parse(response.body)

    # Z-API retorna:
    # {
    #   "connected": boolean,
    #   "error": string,
    #   "smartphoneConnected": boolean
    # }
    {
      connected: parsed_response['connected'] || false,
      error: parsed_response['error'],
      smartphone_connected: parsed_response['smartphoneConnected'] || false
    }
  rescue JSON::ParserError => e
    Rails.logger.error "Z-API: Status JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Z-API status endpoint'
  rescue StandardError => e
    Rails.logger.error "Z-API: Status connection error: #{e.class} - #{e.message}"
    raise "Failed to get status: #{e.message}"
  end

  def update_provider_connection_from_status(whatsapp_channel, status_data)
    return unless whatsapp_channel && status_data.is_a?(Hash)

    connected = status_data[:connected] == true || status_data['connected'] == true
    error_message = status_data[:error] || status_data['error']

    connection_status = connected ? 'open' : 'close'
    formatted_error = error_message.present? ? "Z-API: #{error_message}" : nil

    whatsapp_channel.update_provider_connection!({
      connection: connection_status,
      error: formatted_error
    })
  rescue StandardError => e
    Rails.logger.error "Z-API: Error updating provider connection status: #{e.message}"
  end

  def update_provider_connection_from_qrcode(whatsapp_channel, qrcode_data)
    return unless whatsapp_channel && qrcode_data.is_a?(Hash)

    connected = qrcode_data[:connected] == true || qrcode_data['connected'] == true
    connection_status = connected ? 'open' : 'close'

    whatsapp_channel.update_provider_connection!({
      connection: connection_status,
      error: connected ? nil : 'Z-API: Instance not connected'
    })
  rescue StandardError => e
    Rails.logger.error "Z-API: Error updating provider connection from QR code: #{e.message}"
  end
end
