class Webhooks::InstagramEventsJob < MutexApplicationJob
  queue_as :default
  retry_on LockAcquisitionError, wait: 1.second, attempts: 8

  # @return [Array] We will support further events like reaction or seen in future
  SUPPORTED_EVENTS = [:message, :read].freeze

  def perform(entries)
    @entries = entries

    sender_id_value = sender_id || 'unknown'
    ig_account_id_value = ig_account_id || 'unknown'

    Rails.logger.info("Instagram Events Job: Starting processing - sender_id: #{sender_id_value}, ig_account_id: #{ig_account_id_value}")

    key = format(::Redis::Alfred::IG_MESSAGE_MUTEX, sender_id: sender_id_value, ig_account_id: ig_account_id_value)
    Rails.logger.info("Instagram Events Job: Using lock key: #{key}")

    with_lock(key) do
      process_entries(entries)
    end
  end

  # https://developers.facebook.com/docs/messenger-platform/instagram/features/webhook
  def process_entries(entries)
    entries.each do |entry|
      process_single_entry(entry.with_indifferent_access)
    end
  end

  private

  def process_single_entry(entry)
    if comment_event?(entry)
      process_comments(entry)
      return
    end

    if test_event?(entry)
      process_test_event(entry)
      return
    end

    process_messages(entry)
  end

  # Comments arrive as entry[].changes[] with field 'comments' (not in messaging[]).
  def comment_event?(entry)
    Array(entry[:changes]).any? { |change| change.with_indifferent_access[:field] == 'comments' }
  end

  def process_comments(entry)
    Array(entry[:changes]).each do |change|
      change = change.with_indifferent_access
      next unless change[:field] == 'comments'

      Rails.logger.info("Instagram Events Job: Processing comment #{change.dig(:value, :id)} for ig_account #{entry[:id]}")
      ::Instagram::CommentCreator.new(ig_account_id: entry[:id], value: change[:value]).perform
    end
  end

  def process_messages(entry)
    messaging_array = messages(entry)
    Rails.logger.info("Instagram Events Job: Processing #{messaging_array.length} messaging entries from entry: #{entry[:id]}")

    messaging_array.each_with_index do |messaging, index|
      messaging_indifferent = messaging.with_indifferent_access
      Rails.logger.info("Instagram Events Job Messaging[#{index}]: #{messaging_indifferent.inspect}")
      Rails.logger.info("Instagram Events Job Messaging[#{index}] keys: #{messaging_indifferent.keys.inspect}")

      # Skip unsupported events like message_edit, reactions, etc.
      if unsupported_event?(messaging_indifferent)
        Rails.logger.info("Instagram Events Job: Skipping unsupported event type: #{messaging_indifferent.keys.inspect}")
        next
      end

      # Log sender/recipient info for debugging
      Rails.logger.info("Instagram Events Job Messaging[#{index}] sender: #{messaging_indifferent[:sender].inspect}")
      Rails.logger.info("Instagram Events Job Messaging[#{index}] recipient: #{messaging_indifferent[:recipient].inspect}")
      Rails.logger.info("Instagram Events Job Messaging[#{index}] message: #{messaging_indifferent[:message].inspect}")

      instagram_id = instagram_id(messaging_indifferent, entry)
      Rails.logger.info("Instagram Events Job Messaging[#{index}] resolved instagram_id: #{instagram_id.inspect}")

      unless instagram_id.present?
        Rails.logger.warn("Instagram Events Job: Could not determine instagram_id from messaging: #{messaging_indifferent.inspect}, entry: #{entry[:id]}")
        next
      end

      channel = find_channel(instagram_id)
      Rails.logger.info("Instagram Events Job Messaging[#{index}] found channel: #{channel.inspect}")

      if channel.blank?
        Rails.logger.warn("Instagram Events Job: Channel not found for instagram_id: #{instagram_id}")
        Rails.logger.warn("Instagram Events Job: Searching for Channel::Instagram with instagram_id: #{instagram_id}")
        Rails.logger.warn("Instagram Events Job: Searching for Channel::FacebookPage with instagram_id: #{instagram_id}")
        next
      end

      Rails.logger.info("Instagram Events Job: Found channel #{channel.id} (#{channel.class.name}) for instagram_id: #{instagram_id}")

      event_name_result = event_name(messaging_indifferent)
      Rails.logger.info("Instagram Events Job Messaging[#{index}] event_name result: #{event_name_result.inspect}")

      if event_name_result
        Rails.logger.info("Instagram Events Job: Processing event: #{event_name_result}")
        begin
          send(event_name_result, messaging_indifferent, channel)
          Rails.logger.info("Instagram Events Job: Successfully processed event: #{event_name_result}")
        rescue StandardError => e
          Rails.logger.error("Instagram Events Job: Error processing event #{event_name_result}: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
          raise
        end
      else
        Rails.logger.warn("Instagram Events Job: No supported event found in messaging: #{messaging_indifferent.keys.inspect}")
        Rails.logger.warn("Instagram Events Job: Supported events are: #{SUPPORTED_EVENTS.inspect}")
      end
    end
  end

  def agent_message_via_echo?(messaging)
    messaging[:message].present? && messaging[:message][:is_echo].present?
  end

  def unsupported_event?(messaging)
    # Check if this is an unsupported event type (like message_edit, reaction, etc.)
    # These events don't have sender/recipient and should be skipped
    return false unless messaging.is_a?(Hash)

    messaging_indifferent = messaging.with_indifferent_access
    unsupported_keys = [:message_edit, :reaction, :postback, :account_linking]
    unsupported_keys.any? { |key| messaging_indifferent.key?(key) }
  end

  def test_event?(entry)
    entry[:changes].present?
  end

  def process_test_event(entry)
    messaging = extract_messaging_from_test_event(entry)

    Instagram::TestEventService.new(messaging).perform if messaging.present?
  end

  def extract_messaging_from_test_event(entry)
    entry[:changes].first&.dig(:value) if entry[:changes].present?
  end

  def instagram_id(messaging, entry = nil)
    Rails.logger.info("Instagram Events Job: Resolving instagram_id - messaging keys: #{messaging.keys.inspect}")
    Rails.logger.info("Instagram Events Job: messaging sender: #{messaging[:sender].inspect}, recipient: #{messaging[:recipient].inspect}")
    Rails.logger.info("Instagram Events Job: agent_message_via_echo?: #{agent_message_via_echo?(messaging)}")

    # Try to get instagram_id from sender/recipient first
    if agent_message_via_echo?(messaging)
      sender_id = messaging.dig(:sender, :id)
      Rails.logger.info("Instagram Events Job: Echo message, using sender_id: #{sender_id}")
      return sender_id if sender_id.present?
    else
      recipient_id = messaging.dig(:recipient, :id)
      Rails.logger.info("Instagram Events Job: Normal message, using recipient_id: #{recipient_id}")
      return recipient_id if recipient_id.present?
    end

    # Fallback: try to get from entry's id field (ig_account_id)
    if entry.present?
      entry_id = entry[:id]
      Rails.logger.info("Instagram Events Job: Using fallback entry[:id]: #{entry_id}")
      return entry_id if entry_id.present?
    end

    # Last resort: try to get from @entries
    fallback_id = ig_account_id
    Rails.logger.info("Instagram Events Job: Using last resort ig_account_id: #{fallback_id}")
    fallback_id
  end

  def ig_account_id
    @entries&.first&.dig(:id)
  end

  def sender_id
    # Find the first valid messaging entry that has sender/recipient (not message_edit, etc.)
    @entries&.each do |entry|
      messaging_array = entry[:messaging] || entry[:standby] || []
      messaging_array.each do |messaging|
        # Skip unsupported events
        next if unsupported_event?(messaging.with_indifferent_access)

        # Return sender id if available
        if messaging[:sender]&.dig(:id).present?
          return messaging[:sender][:id]
        end

        # For echo messages, sender is the page/account
        if messaging[:recipient]&.dig(:id).present?
          return messaging[:recipient][:id]
        end
      end
    end

    # Fallback: try to get from entry id (ig_account_id)
    ig_account_id
  end

  def find_channel(instagram_id)
    # There will be chances for the instagram account to be connected to a facebook page,
    # so we need to check for both instagram and facebook page channels
    # priority is for instagram channel which created via instagram login
    Rails.logger.info("Instagram Events Job: Searching for Channel::Instagram with instagram_id: #{instagram_id}")
    channel = Channel::Instagram.find_by(instagram_id: instagram_id)
    Rails.logger.info("Instagram Events Job: Channel::Instagram result: #{channel.inspect}")

    # If not found, fallback to the facebook page channel
    if channel.blank?
      Rails.logger.info("Instagram Events Job: Searching for Channel::FacebookPage with instagram_id: #{instagram_id}")
      channel = Channel::FacebookPage.find_by(instagram_id: instagram_id)
      Rails.logger.info("Instagram Events Job: Channel::FacebookPage result: #{channel.inspect}")
    end

    if channel.present?
      Rails.logger.info("Instagram Events Job: Found channel #{channel.id} (#{channel.class.name}) with instagram_id: #{instagram_id}")
    else
      Rails.logger.warn("Instagram Events Job: No channel found for instagram_id: #{instagram_id}")
      # Log all available channels for debugging
      Rails.logger.warn("Instagram Events Job: Available Channel::Instagram IDs: #{Channel::Instagram.pluck(:instagram_id).inspect}")
      Rails.logger.warn("Instagram Events Job: Available Channel::FacebookPage IDs: #{Channel::FacebookPage.pluck(:instagram_id).compact.inspect}")
    end

    channel
  end

  def event_name(messaging)
    SUPPORTED_EVENTS.find { |key| messaging.key?(key) }
  end

  def message(messaging, channel)
    if channel.is_a?(Channel::Instagram)
      ::Instagram::MessageText.new(messaging, channel).perform
    else
      ::Instagram::Messenger::MessageText.new(messaging, channel).perform
    end
  end

  def read(messaging, channel)
    # Use a single service to handle read status for both channel types since the params are same
    ::Instagram::ReadStatusService.new(params: messaging, channel: channel).perform
  end

  def messages(entry)
    (entry[:messaging].presence || entry[:standby] || [])
  end
end

# Actual response from Instagram webhook (both via Facebook page and Instagram direct)
# [
#   {
#     "time": <timestamp>,
#     "id": <INSTAGRAM_USER_ID>,
#     "messaging": [
#       {
#         "sender": {
#           "id": <INSTAGRAM_USER_ID>
#         },
#         "recipient": {
#           "id": <INSTAGRAM_USER_ID>
#         },
#         "timestamp": <timestamp>,
#         "message": {
#           "mid": <MESSAGE_ID>,
#           "text": <MESSAGE_TEXT>
#         }
#       }
#     ]
#   }
# ]

# Instagram's webhook via Instagram direct testing quirk: Test payloads vs Actual payloads
# When testing in Facebook's developer dashboard, you'll get a Page-style
# payload with a "changes" object. But don't be fooled! Real Instagram DMs
# arrive in the familiar Messenger format with a "messaging" array.
# This apparent inconsistency is actually by design - Instagram's webhooks
# use different formats for testing vs production to maintain compatibility
# with both Instagram Direct and Facebook Page integrations.
# See: https://developers.facebook.com/docs/instagram-platform/webhooks#event-notifications

# Test response from via Instagram direct
# [
#   {
#     "id": "0",
#     "time": <timestamp>,
#     "changes": [
#       {
#         "field": "messages",
#         "value": {
#           "sender": {
#             "id": "12334"
#           },
#           "recipient": {
#             "id": "23245"
#           },
#           "timestamp": "1527459824",
#           "message": {
#             "mid": "random_mid",
#             "text": "random_text"
#           }
#         }
#       }
#     ]
#   }
# ]

# Test response via Facebook page
# [
#   {
#     "time": <timestamp>,,
#     "id": "0",
#     "messaging": [
#       {
#         "sender": {
#           "id": "12334"
#         },
#         "recipient": {
#           "id": "23245"
#         },
#         "timestamp": <timestamp>,
#         "message": {
#             "mid": "random_mid",
#             "text": "random_text"
#         }
#       }
#     ]
#   }
# ]
