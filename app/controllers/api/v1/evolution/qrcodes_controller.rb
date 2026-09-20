class Api::V1::Evolution::QrcodesController < Api::V1::BaseController
  include EvolutionConcern

  require_permissions({
    show: 'inboxes.read',
    create: 'inboxes.update'
  })

  def show
    Rails.logger.info "Evolution API get QR code called for instance: #{params[:id]}"

    begin
      instance_name = params[:id]
      channel = find_whatsapp_channel_by_instance_name(instance_name)

      if channel
        api_url, api_hash = evolution_credentials_for!(channel)

        result = get_qrcode_with_recreate(channel, api_url, api_hash, instance_name)

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
      instance_name = auth_params[:instance_name]

      # Resolve credentials with GlobalConfig fallback for legacy channels
      channel = find_whatsapp_channel_by_instance_name(instance_name)
      api_url, api_hash = resolve_evolution_credentials(channel, auth_params)

      Rails.logger.info "Evolution API: Refreshing QR code for instance #{instance_name}"

      # Get updated QR code
      qrcode_data = get_qrcode_with_recreate(channel, api_url, api_hash, instance_name)

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

  # Archiving a channel can leave Evolution API's own instance deleted (see
  # InstanceNotFoundError) — reconnecting an archived channel would otherwise
  # dead-end on a 404 forever, since nothing else ever recreates it. Recreate
  # once with the channel's own persisted config and retry, so reactivating
  # an archived WhatsApp channel "just works" even when Evolution API no
  # longer has the instance.
  def get_qrcode_with_recreate(channel, api_url, api_hash, instance_name)
    get_qrcode(api_url, api_hash, instance_name)
  rescue InstanceNotFoundError
    # Without a channel record there's no phone_number to recreate with —
    # nothing to do but surface the original 404 (legacy/unmatched instance).
    raise if channel.nil? || channel.phone_number.blank?

    Rails.logger.warn "Evolution API: instance #{instance_name} missing — recreating from channel #{channel.id}"
    # api_hash here IS the admin token: both callers resolve it via
    # evolution_credentials_for!/resolve_evolution_credentials, which return
    # [api_url, admin_token] — the per-instance apikey used for /instance/connect
    # is the same admin credential Evolution API accepts for /instance/create.
    create_evolution_instance!(api_url, api_hash, instance_name, channel.phone_number)
    get_qrcode(api_url, api_hash, instance_name)
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

    raise InstanceNotFoundError, "Evolution instance #{instance_name} does not exist" if response.code == '404'
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
  rescue InstanceNotFoundError
    raise
  rescue JSON::ParserError => e
    Rails.logger.error "Evolution API: QR code JSON parse error: #{e.message}, Body: #{response&.body}"
    raise 'Invalid response from Evolution API connect endpoint'
  rescue StandardError => e
    Rails.logger.error "Evolution API: QR code connection error: #{e.class} - #{e.message}"
    raise "Failed to get QR code: #{e.message}"
  end
end
