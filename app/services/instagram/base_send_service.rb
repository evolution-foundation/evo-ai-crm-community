class Instagram::BaseSendService < Base::SendOnChannelService
  HUB_TOKEN_MISSING = 'Evolution Hub channel token missing — reconnect the channel'.freeze
  HUB_CHANNEL_NOT_LINKED = 'Channel is not connected through the Evolution Hub — reconnect it'.freeze

  pattr_initialize [:message!]

  private

  delegate :additional_attributes, to: :contact

  def perform_reply
    send_attachments if message.attachments.present?
    send_content if message.content.present?
  rescue StandardError => e
    handle_error(e)
  end

  def send_attachments
    message.attachments.each do |attachment|
      send_message(attachment_message_params(attachment))
    end
  end

  def send_content
    send_message(message_params)
  end

  def handle_error(error)
    EvolutionExceptionTracker.new(error, account: nil, user: message.sender).capture_exception
  end

  def message_params
    params = {
      recipient: { id: contact.get_source_id(inbox.id) },
      message: {
        text: strip_html_tags(message.content)
      }
    }

    merge_human_agent_tag(params)
  end

  def attachment_message_params(attachment)
    params = {
      recipient: { id: contact.get_source_id(inbox.id) },
      message: {
        attachment: {
          type: attachment_type(attachment),
          payload: {
            url: attachment.download_url
          }
        }
      }
    }

    merge_human_agent_tag(params)
  end

  # The block builds the direct-to-Meta query; it only runs with the Hub off.
  def post_to_meta(url, message_content)
    response = if MetaBaseUrl.enabled?
                 post_through_hub(url, message_content)
               else
                 HTTParty.post(url, body: message_content, query: yield)
               end
    # Not `response.nil?`: HTTParty::Response answers true to it for an empty body.
    return unless response

    process_response(response, message_content)
  end

  # No token in the query: the proxy forwards it to Meta untouched. A channel the
  # Hub doesn't manage fails here, so its own Meta token never leaves the CRM.
  def post_through_hub(url, message_content)
    token = hub_channel_token
    if token.blank?
      reason = hub_channel? ? HUB_TOKEN_MISSING : HUB_CHANNEL_NOT_LINKED
      Messages::StatusUpdateService.new(message, 'failed', reason).perform
      return false
    end

    HTTParty.post(url, body: message_content, headers: { 'Authorization' => "Bearer #{token}" })
  end

  def hub_channel?
    EvolutionHub::ChannelReconciler.hub_channel_id_of(channel).present?
  end

  # A Hub channel's own Meta token is a placeholder or the Hub's encrypted copy;
  # the proxy authenticates the channel_token.
  def hub_channel_token
    return unless hub_channel?

    token = EvolutionHub::ChannelReconciler.hub_channel_token_of(channel)
    return token if token.present?

    channel.heal_from_hub_if_stale!
    EvolutionHub::ChannelReconciler.hub_channel_token_of(channel)
  end

  def process_response(response, message_content)
    parsed_response = response.parsed_response
    # Meta answers JSON; no body or an ingress error page came from in front of it.
    unless parsed_response.is_a?(Hash)
      Rails.logger.error("Instagram response: #{response.code} without a JSON body : #{message_content}")
      Messages::StatusUpdateService.new(message, 'failed', "#{response.code} - unexpected response").perform
      return
    end

    if response.success? && parsed_response['error'].blank?
      message.update!(source_id: parsed_response['message_id'])
      parsed_response
    else
      external_error = external_error(parsed_response)
      Rails.logger.error("Instagram response: #{external_error} : #{message_content}")
      Messages::StatusUpdateService.new(message, 'failed', external_error).perform
      nil
    end
  end

  def external_error(response)
    error_message = response.dig('error', 'message')
    error_code = response.dig('error', 'code')

    # https://developers.facebook.com/docs/messenger-platform/error-codes
    # Access token has expired or become invalid. This may be due to a password change,
    # removal of the connected app from Instagram account settings, or other reasons.
    channel.authorization_error! if error_code == 190

    "#{error_code} - #{error_message}"
  end

  def attachment_type(attachment)
    return attachment.file_type if %w[image audio video file].include? attachment.file_type

    'file'
  end

  # Methods to be implemented by child classes
  def send_message(message_content)
    raise NotImplementedError, 'Subclasses must implement send_message'
  end

  def merge_human_agent_tag(params)
    raise NotImplementedError, 'Subclasses must implement merge_human_agent_tag'
  end
end
