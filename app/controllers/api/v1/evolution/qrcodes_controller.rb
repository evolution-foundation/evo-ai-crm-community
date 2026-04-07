class Api::V1::Evolution::QrcodesController < Api::V1::BaseController
  def show
    Rails.logger.info "Evolution API get QR code called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url = channel.provider_config['api_url']
        api_hash = channel.provider_config['admin_token']

        result = get_qrcode(api_url, api_hash, instance_name)

        render json: {
          success: true,
          data: result
        }
      else
        render json: { error: "Channel not found for instance: #{instance_name}" }, status: :not_found
      end
    rescue StandardError => e
      Rails.logger.error "Evolution API get QR code error: #{e.class} - #{e.message}"
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def create
    Rails.logger.info "Evolution API QR code refresh called with params: #{params.inspect}"

    begin
      # Extract parameters
      auth_params = params[:qrcode] || params
      api_url = auth_params[:api_url]
      api_hash = auth_params[:api_hash]
      instance_name = auth_params[:instance_name]

      Rails.logger.info "Evolution API: Refreshing QR code for instance #{instance_name}"

      # Get updated QR code
      qrcode_data = get_qrcode(api_url, api_hash, instance_name)

      render json: {
        success: true,
        qrcode: qrcode_data
      }
    rescue StandardError => e
      Rails.logger.error "Evolution API QR code refresh error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_whatsapp_channel_by_instance_name(instance_name)
    Channel::Whatsapp.joins(:inbox)
                     .where(provider: 'evolution')
                     .find do |ch|
      config = ch.provider_config || {}
      candidates = [
        config['instance_name'],
        config['instanceName'],
        config['instance'],
        ch.inbox&.name
      ].compact.uniq
      candidates.include?(instance_name)
    end
  end

  def get_qrcode(api_url, api_hash, instance_name)
    qrcode_url = "#{api_url.chomp('/')}/instance/connect/#{instance_name}"
    Rails.logger.info "Evolution API: Getting QR code from #{qrcode_url}"

    uri = URI.parse(qrcode_url)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 15
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri)
    request['apikey'] = api_hash
    request['Content-Type'] = 'application/json'

    Rails.logger.info "Evolution API: QR code request headers: #{request.to_hash}"

    response = http.request(request)
    Rails.logger.info "Evolution API: QR code response code: #{response.code}"
    Rails.logger.info "Evolution API: QR code response body: #{response.body}"

    raise "Failed to get QR code. Status: #{response.code}, Body: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed_response = JSON.parse(response.body)

    # Check if instance is already connected
    if parsed_response['instance'] && parsed_response['instance']['state'] == 'open'
      return {
        connected: true,
        state: 'open',
        instance_name: parsed_response['instance']['instanceName']
      }
    end

    # Format response to match the frontend expectations
    {
      base64: parsed_response['base64'],
      pairingCode: parsed_response['pairingCode'],
      connected: false
    }
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API connect endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: QR code connection error: #{e.class} - #{e.message}"
    raise "Failed to get QR code: #{e.message}"
  end
end
