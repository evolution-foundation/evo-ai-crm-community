class Api::V1::Waha::QrcodesController < Api::V1::BaseController
  include WahaConcern

  require_permissions({
    show: 'inboxes.read'
  })

  before_action :set_channel

  def show
    base_url = @channel.provider_config['base_url'].to_s.strip.chomp('/')
    api_key = @channel.provider_config['api_key'].to_s.strip
    session_name = @channel.provider_config['session_name'].to_s.strip

    if base_url.blank? || api_key.blank? || session_name.blank?
      return render json: {
        error: 'Missing required WAHA credentials: base_url, api_key, session_name'
      }, status: :bad_request
    end

    response = HTTParty.get(
      "#{base_url}/api/#{session_name}/auth/qr",
      headers: { 'X-Api-Key' => api_key },
      query: { format: 'raw' },
      timeout: 15
    )

    if response.success?
      render json: { qr_data_url: response.parsed_response['value'] }, status: :ok
    else
      render json: { error: "Failed to fetch QR code: #{response.code}" }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "WAHA API: QR code error: #{e.class} - #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
