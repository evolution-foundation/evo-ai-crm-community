# frozen_string_literal: true

# Dedicated durable ingress for the explicitly configured account. Other accounts
# retain their existing receiver. No contact, conversation, read receipt or send.
class Instagram::AmhIngress
  COMMENT_FIELDS = %w[comments live_comments].freeze
  MAX_BODY = 1.megabyte
  Result = Struct.new(:status, :remaining, keyword_init: true)
  class InvalidEvent < StandardError; end

  def initialize(raw:, signature:)
    @raw = raw
    @signature = signature.to_s
  end

  def perform
    return if ENV.fetch('INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID', '').blank?

    return Result.new(status: 413) if @raw.bytesize > MAX_BODY

    body = JSON.parse(@raw)
    return Result.new(status: 400) unless valid_body?(body)

    scoped, remaining = body['entry'].partition { |entry| managed_entry?(entry) }
    return if scoped.empty?

    process_scoped(body, scoped, remaining)
  rescue JSON::ParserError, InvalidEvent
    Result.new(status: 400)
  rescue Instagram::AmhConnection::ConfigurationError, ActiveRecord::ActiveRecordError
    # No ACK on DB/configuration failure or pause: Meta can retry. Never print
    # exception messages, raw entries, codes, profile data or credentials.
    Result.new(status: 503)
  end

  private

  def valid_body?(body)
    body.is_a?(Hash) && body['entry'].is_a?(Array)
  end

  def managed_entry?(entry)
    entry.is_a?(Hash) && Instagram::AmhConnection.managed_account?(entry['id'])
  end

  def enabled?
    ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] == 'true' && ENV['INSTAGRAM_AMH_INGRESS_ENABLED'] == 'true'
  end

  def process_scoped(body, scoped, remaining)
    return Result.new(status: 403) unless valid_signature?
    return Result.new(status: 400) unless body['object'] == 'instagram'

    inbox = Instagram::AmhConnection.bound_inbox!
    return Result.new(status: 503) unless enabled?

    contracts = scoped.flat_map { |entry| normalize(entry) }
    events = Instagram::AmhInboundEvent.transaction(requires_new: true) do
      contracts.map { |contract| persist(inbox, contract) }
    end
    events.each { |event| Instagram::AmhDispatchJob.perform_later(event.id) } if Instagram::AmhExecutor.enabled?
    Result.new(status: 200, remaining: remaining)
  end

  def persist(inbox, contract)
    key = Digest::SHA256.hexdigest(JSON.generate([inbox.id, contract['identity'], contract['kind'], contract['event_id']]))
    Instagram::AmhInboundEvent.create_or_find_by!(event_key: key) do |record|
      record.inbox_id = inbox.id
      record.encrypted_contract = Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(contract)
    end
  end

  def valid_signature?
    secret = GlobalConfigService.load('INSTAGRAM_APP_SECRET', '').to_s
    return false if secret.blank? || !@signature.match?(/\Asha256=[0-9a-f]{64}\z/)

    expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, @raw)}"
    ActiveSupport::SecurityUtils.secure_compare(expected, @signature)
  end

  def numeric_id(value)
    raise InvalidEvent unless value.is_a?(String) && value.match?(/\A[0-9]{1,64}\z/)

    value
  end

  def event_id(value)
    raise InvalidEvent unless value.is_a?(String) && value.present? && value.bytesize <= 128

    value
  end

  def occurred_at(value, milliseconds: false)
    raise InvalidEvent unless value.is_a?(Integer)

    seconds = milliseconds ? value / 1000 : value
    raise InvalidEvent unless seconds.between?(946_684_800, Time.current.to_i + 300)

    Time.at(seconds).utc.iso8601
  end

  def base(entry, person, id, kind, time)
    { 'identity' => { 'professional_account_id' => numeric_id(entry['id']),
                      'app_id' => Instagram::AmhConnection.app_id, 'login_mode' => 'instagram_login',
                      'igsid' => numeric_id(person) },
      'event_id' => event_id(id), 'kind' => kind, 'occurred_at' => time }
  end

  def normalize(entry)
    numeric_id(entry['id'])
    %w[messaging standby changes].each do |field|
      raise InvalidEvent if entry.key?(field) && !entry[field].is_a?(Array)
    end
    messages = Array(entry['messaging']) + Array(entry['standby'])
    messages.filter_map { |message| normalize_dm(entry, message) } +
      Array(entry['changes']).filter_map { |change| normalize_comment(entry, change) }
  end

  def normalize_dm(entry, message)
    return unless message.is_a?(Hash) && message['message'].is_a?(Hash)
    return if message.dig('message', 'is_echo') || message.dig('sender', 'id') == entry['id']

    raise InvalidEvent unless message.dig('recipient', 'id') == entry['id']

    base(entry, message.dig('sender', 'id'), message.dig('message', 'mid'), 'dm',
         occurred_at(message['timestamp'], milliseconds: true))
  end

  def comment_time(value)
    # Meta integrations expose entry.time in seconds or milliseconds.
    occurred_at(value, milliseconds: value.is_a?(Integer) && value >= 1_000_000_000_000)
  end

  def normalize_comment(entry, change)
    return unless change.is_a?(Hash) && COMMENT_FIELDS.include?(change['field'])

    value = change['value']
    raise InvalidEvent unless value.is_a?(Hash) && value['from'].is_a?(Hash)
    return if value.dig('from', 'id') == entry['id'] || value['is_spam'] == true

    contract = base(entry, value.dig('from', 'id'), value['id'], 'comment', comment_time(entry['time']))
    contract['live'] = change['field'] == 'live_comments'
    decorate_comment(contract, value)
  end

  def decorate_comment(contract, value)
    # Do not derive a display name from a mutable username.
    observed = value.dig('from', 'username')
    contract['username'] = observed[0, 64] if observed.is_a?(String)
    contract['time_source'] = 'webhook_entry'
    contract['media_id'] = numeric_id(value.dig('media', 'id')) if value.dig('media', 'id')
    contract['ad_id'] = numeric_id(value['ad_id']) if value['ad_id']
    # Only comment text for later rule matching, encrypted. No DM body or raw webhook.
    contract['comment_text'] = value['text'][0, 2200] if value['text'].is_a?(String)
    contract
  end
end
