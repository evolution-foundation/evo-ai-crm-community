# Turns an Instagram `comments` webhook into an incoming message.
#
# Comments of one person are grouped in a single open "comment conversation"
# (conversation_type: 'instagram_comment'), kept apart from the person's DM
# conversation so the reply routing (public reply vs DM) stays unambiguous.
class Instagram::CommentCreator
  CONVERSATION_TYPE = 'instagram_comment'.freeze

  pattr_initialize [:ig_account_id!, :value!]

  def perform
    return unless parser.valid?

    channel = Channel::Instagram.find_by(instagram_id: ig_account_id.to_s)
    return log_skip("no channel for instagram_id #{ig_account_id}") if channel.blank?

    inbox = channel.inbox
    return log_skip("channel #{channel.id} has no inbox") if inbox.blank?
    return if channel.reauthorization_required?

    # Our own replies (sent from the CRM or from the app) come back as comments.
    return log_skip("own comment #{parser.comment_id}") if parser.from_id.to_s == channel.instagram_id.to_s
    return log_skip("comment #{parser.comment_id} already exists") if Message.exists?(inbox_id: inbox.id, source_id: parser.comment_id)

    contact_inbox = find_or_create_contact_inbox(inbox)
    conversation = find_or_create_conversation(inbox, contact_inbox)
    create_message(conversation, contact_inbox.contact, channel)
  end

  private

  def parser
    @parser ||= Instagram::CommentParser.new(value)
  end

  def log_skip(reason)
    Rails.logger.info("[Instagram::CommentCreator] skipped: #{reason}")
    nil
  end

  def find_or_create_contact_inbox(inbox)
    ::ContactInboxWithContactBuilder.new(
      source_id: parser.from_id,
      inbox: inbox,
      contact_attributes: {
        name: parser.username.presence || "Instagram #{parser.from_id.to_s[0..10]}",
        additional_attributes: { social_profiles: { instagram: parser.username }.compact }
      }
    ).perform
  end

  def find_or_create_conversation(inbox, contact_inbox)
    existing = Conversation.where(inbox_id: inbox.id, contact_id: contact_inbox.contact_id)
                           .where("additional_attributes->>'conversation_type' = ?", CONVERSATION_TYPE)
                           .where.not(status: :resolved)
                           .order(created_at: :desc)
                           .first
    return existing if existing

    Conversation.create!(
      inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      status: :open,
      additional_attributes: { conversation_type: CONVERSATION_TYPE }
    )
  end

  def create_message(conversation, contact, channel)
    permalink = fetch_media_permalink(channel)

    conversation.messages.create!(
      inbox_id: conversation.inbox_id,
      message_type: :incoming,
      content: message_content(permalink),
      source_id: parser.comment_id,
      sender: contact,
      content_attributes: {
        instagram_comment: true,
        comment_id: parser.comment_id,
        in_reply_to_external_id: parser.parent_id.presence,
        media_id: parser.media_id,
        media_product_type: parser.media_product_type,
        media_permalink: permalink
      }.compact
    )
  end

  # The agent needs to know WHICH post was commented on.
  def message_content(permalink)
    return parser.text.to_s if permalink.blank?

    "#{parser.text}\n\n🔗 Publicação: #{permalink}"
  end

  # Best effort: never block the comment on a failed lookup.
  def fetch_media_permalink(channel)
    return nil if parser.media_id.blank? || MetaBaseUrl.enabled?

    response = HTTParty.get(
      "#{MetaBaseUrl.for(:instagram)}/#{parser.media_id}",
      query: { fields: 'permalink', access_token: channel.access_token },
      timeout: 10
    )
    response.success? ? response.parsed_response['permalink'] : nil
  rescue StandardError => e
    Rails.logger.warn("[Instagram::CommentCreator] media permalink lookup failed: #{e.class}")
    nil
  end
end
