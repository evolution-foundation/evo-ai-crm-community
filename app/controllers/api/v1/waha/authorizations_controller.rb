class Api::V1::Waha::AuthorizationsController < Api::V1::BaseController
  include WahaConcern

  require_permissions({
    create: 'inboxes.create',
    logout: 'inboxes.update'
  })

  before_action :set_channel, only: [:logout]

  def create
    base_url = params.dig(:authorization, :base_url).to_s.strip
    api_key = params.dig(:authorization, :api_key).to_s.strip
    session_name = params.dig(:authorization, :session_name).to_s.strip
    phone_number = params.dig(:authorization, :phone_number).to_s.strip

    missing_params = []
    missing_params << 'base_url' if base_url.blank?
    missing_params << 'api_key' if api_key.blank?
    missing_params << 'session_name' if session_name.blank?
    missing_params << 'phone_number' if phone_number.blank?

    if missing_params.any?
      return render json: {
        error: "Missing required parameters: #{missing_params.join(', ')}"
      }, status: :bad_request
    end

    begin
      session_response = create_waha_session(base_url, api_key, session_name)
    rescue StandardError => e
      Rails.logger.error "WAHA API: Session creation error: #{e.class} - #{e.message}"
      return render json: { error: "Failed to create WAHA session: #{e.message}" }, status: :unprocessable_entity
    end

    unless session_response.success?
      Rails.logger.error "WAHA API: Session creation failed. Status: #{session_response.code}, Body: #{session_response.body}"
      return render json: { error: "Failed to create WAHA session: #{session_response.code}" }, status: :unprocessable_entity
    end

    channel = Channel::Whatsapp.new(
      phone_number: phone_number,
      provider: 'waha',
      provider_config: { 'base_url' => base_url, 'api_key' => api_key, 'session_name' => session_name }
    )

    if channel.save
      ::Inbox.create!(channel: channel, name: "WAHA #{phone_number}")
      render json: { id: channel.id, session_name: session_name }, status: :ok
    else
      render json: { error: channel.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def logout
    @channel.provider_service.disconnect_channel_provider
    head :ok
  end
end
