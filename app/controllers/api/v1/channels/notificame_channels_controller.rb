class Api::V1::Channels::NotificameChannelsController < Api::V1::BaseController
  skip_before_action :authenticate_user!, :authenticate_access_token!, :set_current_user, raise: false

  def verify
    missing = missing_params
    return missing_params_response(missing) if missing.any?

    channels = Whatsapp::Providers::NotificameService.list_channels(verify_params[:api_token])
    return list_failed_response if channels.blank?

    return channel_not_found_response unless channel_matches?(channels, verify_params[:channel_id])

    success_response(
      data: { success: true, channels: channels },
      message: 'Notificame connection verified successfully'
    )
  rescue StandardError => e
    Rails.logger.error "Notificame verify error: #{e.class} - #{e.message}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def verify_params
    @verify_params ||= {
      api_token: params[:api_token].to_s.strip,
      channel_id: params[:channel_id].to_s.strip,
      phone_number: params[:phone_number].to_s.strip
    }
  end

  def missing_params
    verify_params.select { |_k, v| v.blank? }.keys.map(&:to_s)
  end

  def missing_params_response(missing)
    error_response(
      ApiErrorCodes::MISSING_REQUIRED_FIELD,
      "Missing required parameters: #{missing.join(', ')}",
      status: :bad_request
    )
  end

  def list_failed_response
    error_response(
      ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
      'Could not list Notificame channels. Verify the API Token.',
      status: :unprocessable_entity
    )
  end

  def channel_not_found_response
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      "Channel ID '#{verify_params[:channel_id]}' was not found for the provided API Token.",
      status: :unprocessable_entity
    )
  end

  def channel_matches?(channels, channel_id)
    channels.any? do |entry|
      next false unless entry.is_a?(Hash)

      [entry['id'], entry['channel_id'], entry['channelId'], entry['uuid']]
        .compact.map(&:to_s).include?(channel_id)
    end
  end
end
