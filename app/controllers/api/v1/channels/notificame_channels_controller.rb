class Api::V1::Channels::NotificameChannelsController < Api::V1::BaseController
  before_action :authorize_request

  def verify
    missing = missing_params
    return missing_params_response(missing) if missing.any?

    channels = Whatsapp::Providers::NotificameService.list_channels(verify_params[:api_token])
    return list_failed_response if channels.blank?

    matched_channel = find_channel(channels, verify_params[:channel_id])
    return channel_not_found_response unless matched_channel
    return phone_mismatch_response unless phone_number_matches?(matched_channel, verify_params[:phone_number])

    success_response(
      data: { channels: channels },
      message: 'Notificame connection verified successfully'
    )
  rescue StandardError => e
    Rails.logger.error "Notificame verify error: #{e.class} - #{e.message}"
    # Generic message: e.message can carry HTTP body fragments or internal
    # data we don't want exposed to clients. Keep a friendly 422 for the
    # common case (invalid token / Notificame unreachable); the global
    # handle_internal_error filters details in production for true 500s.
    error_response(
      ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
      'Could not verify Notificame connection. Please check the API token and try again.',
      status: :unprocessable_entity
    )
  end

  private

  def authorize_request
    authorize ::Inbox, :create?
  end

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

  def phone_mismatch_response
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      "Phone number does not match channel '#{verify_params[:channel_id]}'.",
      status: :unprocessable_entity
    )
  end

  def find_channel(channels, channel_id)
    target = channel_id.to_s.strip.downcase
    channels.find do |entry|
      next false unless entry.is_a?(Hash)

      [entry['id'], entry['channel_id'], entry['channelId'], entry['uuid']]
        .compact
        .map { |v| v.to_s.strip.downcase }
        .include?(target)
    end
  end

  # Compare digits-only to ignore E.164 `+` prefix and any formatting
  # punctuation the operator may have typed.
  def phone_number_matches?(channel, expected_phone)
    candidates = [channel['phone'], channel['phone_number'], channel['phoneNumber'], channel['msisdn']]
                 .compact.map { |v| v.to_s.gsub(/\D/, '') }
    expected = expected_phone.to_s.gsub(/\D/, '')
    return false if expected.blank?

    candidates.include?(expected)
  end
end
