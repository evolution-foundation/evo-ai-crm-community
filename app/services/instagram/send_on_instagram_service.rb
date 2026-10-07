class Instagram::SendOnInstagramService < Instagram::BaseSendService
  private

  def channel_class
    Channel::Instagram
  end

  # Deliver a message with the given payload.
  # https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/messaging-api
  def send_message(message_content)
    url = "#{MetaBaseUrl.for(:instagram)}/#{channel.instagram_id.presence || 'me'}/messages"

    post_to_meta(url, message_content) { { access_token: channel.access_token } }
  end

  def merge_human_agent_tag(params)
    global_config = GlobalConfig.get('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')

    return params unless global_config['ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT']

    params[:messaging_type] = 'MESSAGE_TAG'
    params[:tag] = 'HUMAN_AGENT'
    params
  end
end
