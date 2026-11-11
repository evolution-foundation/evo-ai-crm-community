# frozen_string_literal: true

# Decides whether a group message @-mentions the Evolution Go inbox's own number.
#
# Mentions arrive as JIDs in contextInfo.mentionedJID. Phone-addressed groups use
# the phone JID (with or without the Brazilian 9th digit, sometimes with a device
# suffix); LID-addressed groups use the account's LID, which the CRM does not
# store — it is resolved once through Evolution Go's POST /user/info and cached.
# A failed lookup degrades to phone-only matching instead of raising.
class Whatsapp::EvolutionGoBotMentionMatcher
  LID_CACHE_TTL = 24.hours
  # A failed or empty lookup is cached too (as ''), briefly: the listener runs
  # inline, so retrying on every LID mention would stall each group message.
  LID_MISS_CACHE_TTL = 10.minutes
  LID_LOOKUP_TIMEOUT = 3

  def initialize(channel)
    @channel = channel
  end

  def mentioned?(jids)
    lid_jids, phone_jids = Array(jids).map(&:to_s).reject(&:blank?).partition { |jid| jid.end_with?('@lid') }

    phone_mentioned?(phone_jids) || lid_mentioned?(lid_jids)
  end

  private

  def phone_mentioned?(jids)
    jids.any? { |jid| phone_variants.include?(jid_user(jid)) }
  end

  # Only LID mentions pay for the (cached) lookup.
  def lid_mentioned?(jids)
    return false if jids.empty?

    lid = bot_lid
    lid.present? && jids.any? { |jid| jid_user(jid) == lid }
  end

  # "5571991589983:12@s.whatsapp.net" -> "5571991589983"
  def jid_user(jid)
    jid.to_s.split('@').first.to_s.split(':').first.to_s.gsub(/\D/, '')
  end

  def phone_digits
    @phone_digits ||= @channel.phone_number.to_s.gsub(/\D/, '')
  end

  # Brazilian mobiles show up both with and without the 9th digit after the DDD.
  # Only mobiles (subscriber starting 6-9) get the extra variant — never landlines.
  def phone_variants
    @phone_variants ||= [phone_digits, brazilian_mobile_variant].compact.reject(&:blank?)
  end

  def brazilian_mobile_variant
    return nil unless phone_digits.start_with?('55')

    if phone_digits.length == 13 && phone_digits[4] == '9'
      phone_digits[0, 4] + phone_digits[5..]
    elsif phone_digits.length == 12 && phone_digits[4].to_i >= 6
      "#{phone_digits[0, 4]}9#{phone_digits[4..]}"
    end
  end

  def bot_lid
    return @bot_lid if defined?(@bot_lid)

    key = "evolution_go:bot_lid:#{@channel.id}:#{phone_digits}"
    cached = Rails.cache.read(key)
    if cached.nil?
      cached = fetch_bot_lid.to_s
      Rails.cache.write(key, cached, expires_in: cached.empty? ? LID_MISS_CACHE_TTL : LID_CACHE_TTL)
    end
    @bot_lid = cached.presence
  end

  def fetch_bot_lid
    api_url = @channel.provider_config['api_url'].to_s.chomp('/')
    return nil if api_url.blank? || phone_digits.blank?

    response = request_user_info(api_url)
    response.success? ? lid_from(response.parsed_response) : nil
  rescue StandardError => e
    Rails.logger.warn "[Evolution Go] Bot LID lookup failed for channel #{@channel.id}: #{e.class}: #{e.message}"
    nil
  end

  def request_user_info(api_url)
    HTTParty.post(
      "#{api_url}/user/info",
      headers: { 'apikey' => @channel.provider_config['instance_token'], 'Content-Type' => 'application/json' },
      body: { number: phone_variants }.to_json,
      timeout: LID_LOOKUP_TIMEOUT
    )
  end

  # { "data" => { "Users" => { "<jid>" => { "LID" => "123@lid", ... } } } }
  def lid_from(body)
    users = body.is_a?(Hash) ? body.dig('data', 'Users') : nil
    lid = Array(users&.values).filter_map { |user| user['LID'] if user.is_a?(Hash) }.first
    lid.present? ? jid_user(lid) : nil
  end
end
