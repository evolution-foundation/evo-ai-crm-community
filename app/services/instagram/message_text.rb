class Instagram::MessageText < Instagram::BaseMessageText
  attr_reader :messaging

  def ensure_contact(ig_scope_id)
    Rails.logger.info("[Instagram::MessageText] ensure_contact called with ig_scope_id: #{ig_scope_id}")
    result = fetch_instagram_user(ig_scope_id)
    Rails.logger.info("[Instagram::MessageText] fetch_instagram_user result: #{result.inspect}")

    # Use ig_scope_id as fallback if API didn't return user data
    if result.blank? || result['id'].blank?
      Rails.logger.warn('[Instagram::MessageText] fetch_instagram_user returned empty result or nil id, using ig_scope_id as fallback')
      result = { 'id' => ig_scope_id, 'name' => nil }.with_indifferent_access
    end

    Rails.logger.info("[Instagram::MessageText] Calling find_or_create_contact with result: #{result.inspect}")
    find_or_create_contact(result)
    Rails.logger.info("[Instagram::MessageText] After find_or_create_contact, contact_inbox: #{@contact_inbox.inspect}")
  end

  # Busca nome/username/foto do contato. Em Hub mode roteia pelo proxy /meta do EvoHub
  # com `Authorization: Bearer {channel_token}` (o access_token DIRETO no Graph é o
  # channel_token opaco → 190 → authorization_error! prendia o canal e o MessageBuilder
  # engolia a DM). Direto-no-Meta (não-Hub) mantém o ?access_token= de sempre.
  # ⚠️ O token do Bearer é evolution_hub_meta['channel_token'] (o getter access_token é
  # sobrescrito por RefreshOauthTokenService e retorna 'hub-managed-…', NÃO o token real).
  # 'profile_pic' é o campo do contato (sender-scoped id); 'profile_picture_url' só existe
  # p/ business account — process_successful_response lê os dois (fallback).
  def fetch_instagram_user(ig_scope_id)
    fetcher = Instagram::ContactProfileFetcher.new(inbox: @inbox)
    log_profile_request(fetcher, ig_scope_id)
    response = fetcher.call(ig_scope_id)
    log_profile_response(response)
    return failed_profile_response(response) unless response.success?

    parsed_body = parse_profile_body(response)
    return empty_profile_response(ig_scope_id) if parsed_body.blank?
    return embedded_error_response(response, parsed_body) if parsed_body['error'].present?

    result = process_successful_response(response)
    Rails.logger.info("[Instagram::MessageText] Processed successful response: #{result.inspect}")
    result
  end

  def process_successful_response(response)
    result = JSON.parse(response.body).with_indifferent_access
    # O contato (sender-scoped id) expõe `profile_pic`; só o business account expõe
    # `profile_picture_url`. O código antigo lia SÓ profile_picture_url → avatar do
    # contato sempre nil (bug latente, Hub e não-Hub). Preferir profile_pic, fallback url.
    pic = result['profile_pic'].presence || result['profile_picture_url'].presence
    {
      'id' => result['id'],
      'name' => result['name'],
      'username' => result['username'],
      'profile_pic' => pic,
      'profile_picture_url' => pic
    }.with_indifferent_access
  end

  def handle_error_response(response)
    parsed_response = response.parsed_response
    error_message = parsed_response.dig('error', 'message')
    error_code = parsed_response.dig('error', 'code')

    Rails.logger.warn(
      "[Instagram::MessageText] Instagram API error - code: #{error_code}, " \
      "message: #{error_message}, full_response: #{parsed_response.inspect}"
    )
    handle_authorization_error(error_code)
    return log_missing_user_consent if error_code == 230

    Rails.logger.warn("[InstagramUserFetchError]: inbox_id #{@inbox.id}")
    Rails.logger.warn("[InstagramUserFetchError]: #{error_message} #{error_code}")

    exception = StandardError.new("#{error_message} (Code: #{error_code})")
    EvolutionExceptionTracker.new(exception, account: nil).capture_exception
  end

  def handle_authorization_error(error_code)
    return unless error_code == 190

    Rails.logger.error(
      '[Instagram::MessageText] Access token expired or invalid (error 190), ' \
      'marking channel as requiring reauthorization'
    )
    channel.authorization_error!
  end

  def log_missing_user_consent
    Rails.logger.info(
      '[Instagram::MessageText] User consent required (error 230) - ' \
      'this is expected for first-time users. Using ig_scope_id as fallback.'
    )
  end

  def log_profile_request(fetcher, ig_scope_id)
    source = fetcher.hub? ? 'via Hub proxy' : 'from Instagram API'
    Rails.logger.info("[Instagram::MessageText] Fetching user #{source} - ig_scope_id: #{ig_scope_id}")
  end

  def log_profile_response(response)
    Rails.logger.info(
      "[Instagram::MessageText] Instagram API response - status: #{response.code}, " \
      "success?: #{response.success?}, body: #{response.body.inspect}"
    )
  end

  def parse_profile_body(response)
    JSON.parse(response.body)
  rescue JSON::ParserError
    {}
  end

  def failed_profile_response(response)
    handle_error_response(response)
    {}
  end

  def empty_profile_response(ig_scope_id)
    Rails.logger.warn(
      '[Instagram::MessageText] Instagram API returned an empty response; ' \
      "user consent or profile permission may be missing. User ID: #{ig_scope_id}"
    )
    {}
  end

  def embedded_error_response(response, parsed_body)
    Rails.logger.warn(
      "[Instagram::MessageText] Instagram API returned an error body: #{parsed_body['error'].inspect}"
    )
    failed_profile_response(response)
  end

  def create_message
    Rails.logger.info("[Instagram::MessageText] create_message called - contact_inbox: #{@contact_inbox.inspect}")

    unless @contact_inbox
      Rails.logger.warn('[Instagram::MessageText] contact_inbox is nil, cannot create message')
      return
    end

    Rails.logger.info('[Instagram::MessageText] Creating message via MessageBuilder')
    result = Messages::Instagram::MessageBuilder.new(@messaging, @inbox, outgoing_echo: agent_message_via_echo?).perform
    Rails.logger.info("[Instagram::MessageText] MessageBuilder result: #{result.inspect}")
    result
  end
end
