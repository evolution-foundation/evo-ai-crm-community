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

    # Verify-only: this endpoint's job is to create/start the WAHA session on
    # the WAHA server (an external side effect) and register the webhook —
    # exactly like evolution_go's /authorization#create only verifies/creates
    # the remote instance. Persisting the CRM Channel::Whatsapp + Inbox is left
    # entirely to the frontend's subsequent generic InboxesService.createChannel
    # call (same phone_number). Persisting a channel here as well would make
    # that second call fail on the phone_number uniqueness constraint and leave
    # an orphaned Inbox with nothing to ever clean it up.
    session_status = session_response.parsed_response.is_a?(Hash) ? session_response.parsed_response['status'] : nil

    render json: { session_name: session_name, status: session_status }, status: :ok
  end

  def logout
    @channel.provider_service.disconnect_channel_provider
    head :ok
  end
end
