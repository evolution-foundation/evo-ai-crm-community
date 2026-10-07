class Instagram::SendOnInstagramService < Instagram::BaseSendService
  HUB_TOKEN_MISSING = 'Evolution Hub channel token missing — reconnect the channel'.freeze
  HUB_CHANNEL_NOT_LINKED = 'Channel is not connected through the Evolution Hub — reconnect it'.freeze

  private

  def channel_class
    Channel::Instagram
  end

  # Deliver a message with the given payload.
  # https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/messaging-api
  def send_message(message_content)
    url = "#{MetaBaseUrl.for(:instagram)}/#{channel.instagram_id.presence || 'me'}/messages"

    response = if MetaBaseUrl.enabled?
                 post_through_hub(url, message_content)
               else
                 HTTParty.post(url, body: message_content, query: { access_token: channel.access_token })
               end
    # Not `response.nil?`: HTTParty::Response answers true to it for an empty body.
    return unless response

    process_response(response, message_content)
  end

  # The Hub's /meta proxy authenticates the Bearer and forwards the query to Meta
  # untouched, so a token left in the query would reach Meta next to the real one.
  # Returns false, without calling out, when there is no channel token to send.
  # A channel connected straight to Meta has none: the proxy only authenticates Hub
  # channels, and its own Meta token must not leave the CRM.
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

  # The access_token of a Hub channel only holds a placeholder or the Hub's encrypted
  # copy; the proxy authenticates the channel_token.
  def hub_channel_token
    return unless hub_channel?

    token = EvolutionHub::ChannelReconciler.hub_channel_token_of(channel)
    return token if token.present?

    channel.heal_from_hub_if_stale!
    EvolutionHub::ChannelReconciler.hub_channel_token_of(channel)
  end

  def merge_human_agent_tag(params)
    global_config = GlobalConfig.get('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')

    return params unless global_config['ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT']

    params[:messaging_type] = 'MESSAGE_TAG'
    params[:tag] = 'HUMAN_AGENT'
    params
  end
end
