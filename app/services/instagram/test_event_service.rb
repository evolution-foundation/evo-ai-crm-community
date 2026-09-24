class Instagram::TestEventService
  # The fixed pair Meta's developer dashboard sends when it tests the webhook
  # (see the payload notes at the end of Webhooks::InstagramEventsJob).
  TEST_SENDER_ID = '12334'.freeze
  TEST_RECIPIENT_ID = '23245'.freeze

  # Every shape this says no to comes off the wire, so reading one must never raise:
  # a TypeError here loses the entry, which is the bug the predicate exists to stop.
  def self.test_event?(messaging)
    return false unless messaging.is_a?(Hash)

    value = messaging.with_indifferent_access
    return false unless value[:sender].is_a?(Hash) && value[:recipient].is_a?(Hash)

    value.dig(:sender, :id).to_s == TEST_SENDER_ID && value.dig(:recipient, :id).to_s == TEST_RECIPIENT_ID
  end

  # `changes` comes off the wire: only an array whose first item is an object carrying an
  # object `value` has a messaging to read, and anything else is nil rather than a TypeError.
  def self.messaging_from(changes)
    first = changes.first if changes.is_a?(Array)
    value = first.with_indifferent_access[:value] if first.is_a?(Hash)
    value if value.is_a?(Hash)
  end

  def initialize(messaging)
    @messaging = messaging
  end

  def perform
    Rails.logger.info("Processing Instagram test webhook event, #{@messaging}")

    return false unless test_webhook_event?

    create_test_text
  end

  private

  def test_webhook_event?
    self.class.test_event?(@messaging)
  end

  def create_test_text
    # As of now, we are using the last created instagram channel as the test channel,
    # since we don't have any other channel for testing purpose at the time of meta approval
    channel = Channel::Instagram.last

    @inbox = ::Inbox.find_by(channel: channel)
    return unless @inbox

    @contact = create_test_contact

    @conversation ||= create_test_conversation(conversation_params)

    @message = @conversation.messages.create!(test_message_params)
  end

  def create_test_contact
    @contact_inbox = @inbox.contact_inboxes.where(source_id: @messaging[:sender][:id]).first
    unless @contact_inbox
      @contact_inbox ||= @inbox.channel.create_contact_inbox(
        'sender_username', 'sender_username'
      )
    end

    @contact_inbox.contact
  end

  def create_test_conversation(conversation_params)
    Conversation.find_by(conversation_params) || build_conversation(conversation_params)
  end

  def test_message_params
    {
      inbox_id: @conversation.inbox_id,
      message_type: 'incoming',
      source_id: @messaging[:message][:mid],
      content: @messaging[:message][:text],
      sender: @contact
    }
  end

  def build_conversation(conversation_params)
    Conversation.create!(
      conversation_params.merge(
        contact_inbox_id: @contact_inbox.id
      )
    )
  end

  def conversation_params
    {
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      additional_attributes: {
        type: 'instagram_direct_message'
      }
    }
  end
end
