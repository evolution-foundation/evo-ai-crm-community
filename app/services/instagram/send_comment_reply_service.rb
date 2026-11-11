# Sends the agent's reply inside an Instagram comment conversation.
#
# Default: public reply to a comment
#   POST /{comment_id}/replies  (message=...)
# When content_attributes['instagram_reply_mode'] == 'private': private reply,
# i.e. a DM that opens the thread with the commenter
#   POST /{ig_id}/messages  (recipient: { comment_id })
#
# The target comment is the one the agent replied to (in_reply_to) or, when the
# agent just typed in the conversation, the latest comment of the customer.
# https://developers.facebook.com/docs/instagram-platform/comment-moderation
# https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/messaging-api/private-replies
class Instagram::SendCommentReplyService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Instagram
  end

  def perform_reply
    return if reply_text.blank?

    comment_id = target_comment_id
    raise StandardError, "Comment ID not found for reply message #{message.id}" if comment_id.blank?

    response = private_reply? ? send_private_reply(comment_id) : send_public_reply(comment_id)
    handle_response(response)
  rescue StandardError => e
    Rails.logger.error("[Instagram::SendCommentReplyService] #{e.class}: #{e.message}")
    Messages::StatusUpdateService.new(message, 'failed', e.message.to_s.truncate(500)).perform
  end

  # The composer prepends the agent's signature ("<strong>Name:</strong> ") when the
  # agent has it enabled. Public comment replies must not carry the agent's name.
  def reply_text
    strip_html_tags(remove_agent_signature(message.content.to_s)).strip
  end

  def remove_agent_signature(text)
    signature = message.sender.try(:message_signature).to_s.strip
    return text if signature.blank?

    escaped = Regexp.escape(signature)
    text.sub(%r{<strong>\s*#{escaped}\s*:</strong>\s*}i, '').sub(/\A\s*\*#{escaped}:\*\s*/, '')
  end

  def private_reply?
    message.content_attributes&.dig('instagram_reply_mode') == 'private'
  end

  def target_comment_id
    attrs = message.content_attributes || {}
    return attrs['in_reply_to_external_id'] if attrs['in_reply_to_external_id'].present?

    if attrs['in_reply_to'].present?
      parent = conversation.messages.find_by(id: attrs['in_reply_to'])
      return parent.source_id if parent&.source_id.present?
    end

    # Every incoming message of a comment conversation is a comment. Do not filter by
    # content_attributes in SQL: the column holds a JSON *string*, so ->> returns NULL.
    # `reorder`: Message has `default_scope { order(created_at: :asc) }`, and a plain
    # `order(desc)` would only be appended to it, returning the OLDEST comment.
    conversation.messages.incoming
                .where.not(source_id: nil)
                .reorder(created_at: :desc)
                .pick(:source_id)
  end

  def send_public_reply(comment_id)
    HTTParty.post(
      "#{MetaBaseUrl.for(:instagram)}/#{comment_id}/replies",
      query: { access_token: channel.access_token },
      body: { message: reply_text },
      timeout: 30
    )
  end

  def send_private_reply(comment_id)
    instagram_id = channel.instagram_id.presence || 'me'
    HTTParty.post(
      "#{MetaBaseUrl.for(:instagram)}/#{instagram_id}/messages",
      query: { access_token: channel.access_token },
      body: {
        recipient: { comment_id: comment_id },
        message: { text: reply_text }
      }.to_json,
      headers: { 'Content-Type' => 'application/json' },
      timeout: 30
    )
  end

  def handle_response(response)
    parsed = response.parsed_response
    parsed = {} unless parsed.is_a?(Hash)

    if response.success? && parsed['error'].blank?
      # replies -> { id }, private reply -> { recipient_id, message_id }
      message.update!(source_id: parsed['id'] || parsed['message_id'])
      return parsed
    end

    error_code = parsed.dig('error', 'code')
    channel.authorization_error! if error_code == 190
    Messages::StatusUpdateService.new(message, 'failed', "#{error_code} - #{parsed.dig('error', 'message')}").perform
    nil
  end
end
