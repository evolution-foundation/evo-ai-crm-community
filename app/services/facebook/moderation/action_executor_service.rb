# Service to execute approved moderation actions
# Handles deletion of comments, blocking users, and sending responses
require 'net/http'
require 'uri'
require 'json'

class Facebook::Moderation::ActionExecutorService
  attr_reader :moderation

  def initialize(moderation)
    @moderation = moderation
  end

  def delete_comment
    return false unless moderation.present?

    comment_id = moderation.comment_id
    channel = moderation.conversation.inbox.channel

    unless comment_id.present?
      Rails.logger.error "[Moderation] Message ID is missing"
      return false
    end

    # For Facebook channels, delete from Facebook API
    if channel.is_a?(Channel::FacebookPage)
      unless channel.page_access_token.present?
        Rails.logger.error "[Moderation] Page access token is missing for channel #{channel.id}"
        return false
      end

      Rails.logger.info "[Moderation] Deleting comment #{comment_id} from Facebook post"

      # First, find and delete all reply messages (responses to this comment)
      delete_reply_messages(comment_id, moderation.conversation)

      # Then delete the main comment from Facebook
      result = delete_comment_via_api(comment_id, channel)

      if result
        Rails.logger.info "[Moderation] Successfully deleted comment #{comment_id} from Facebook"
      else
        Rails.logger.error "[Moderation] Failed to delete comment #{comment_id} from Facebook"
      end

      return result
    else
      # For other channels, just delete from system
      Rails.logger.info "[Moderation] Deleting message #{comment_id} from system (non-Facebook channel)"

      # Find and delete all reply messages (responses to this message)
      delete_reply_messages(comment_id, moderation.conversation)

      # Delete the main message from the system
      message = moderation.message
      if message.present?
        begin
          message.destroy
          Rails.logger.info "[Moderation] Successfully deleted message #{message.id} from system"
          true
        rescue StandardError => e
          Rails.logger.error "[Moderation] Error deleting message #{message.id} from system: #{e.message}"
          false
        end
      else
        Rails.logger.warn "[Moderation] Message not found for comment_id: #{comment_id}"
        false
      end
    end
  end

  def block_user
    return false unless moderation.present?

    # Get user ID from the comment
    comment_id = moderation.comment_id
    channel = moderation.conversation.inbox.channel

    return false unless channel.is_a?(Channel::FacebookPage)
    return false unless comment_id.present?

    Rails.logger.info "[Facebook Moderation] Blocking user for comment #{comment_id}"

    # First get the comment to find the user ID
    user_id = get_comment_author_id(comment_id, channel)
    return false unless user_id.present?

    block_user_via_api(user_id, channel)
  end

  def send_response
    return false unless moderation.present?
    return false unless moderation.response_content.present?

    conversation = moderation.conversation
    response_content = moderation.response_content
    comment_id = moderation.comment_id

    Rails.logger.info "[Facebook Moderation] Sending response to comment #{comment_id}"

    # Create message attributes
    message_attributes = build_message_attributes(conversation, response_content, comment_id)

    # Create message through conversation.messages to ensure callbacks are executed
    # The send_reply callback will automatically enqueue SendReplyJob which will send the comment
    # We don't need to call Facebook::SendCommentService.perform directly here
    message = conversation.messages.create!(message_attributes)

    Rails.logger.info "[Facebook Moderation] Message created: #{message.id}, SendReplyJob will be enqueued by callback"
    true
  rescue StandardError => e
    Rails.logger.error "[Facebook Moderation] Error sending response: #{e.message}"
    Rails.logger.error(e.backtrace.join("\n"))
    false
  end

  private

  # Delete all reply messages (responses) to a comment
  # This recursively deletes all nested replies
  def delete_reply_messages(comment_id, conversation)
    return unless comment_id.present?
    return unless conversation.present?

    Rails.logger.info "[Facebook Moderation] Finding reply messages for comment #{comment_id}"

    # Find all messages that are replies to this comment
    # Replies have in_reply_to_external_id matching the comment_id
    reply_messages = conversation.messages.where(
      "content_attributes->>'in_reply_to_external_id' = ?",
      comment_id.to_s
    )

    Rails.logger.info "[Facebook Moderation] Found #{reply_messages.count} reply messages for comment #{comment_id}"

    reply_messages.find_each do |reply_message|
      Rails.logger.info "[Facebook Moderation] Processing reply message #{reply_message.id} (source_id: #{reply_message.source_id})"

      # Recursively delete replies to this reply (nested replies)
      if reply_message.source_id.present?
        delete_reply_messages(reply_message.source_id, conversation)
      end

      # Delete moderation records for this reply
      FacebookCommentModeration.where(message: reply_message).destroy_all

      # Delete the reply message from Facebook if it has a source_id
      if reply_message.source_id.present?
        Rails.logger.info "[Facebook Moderation] Deleting reply comment #{reply_message.source_id} from Facebook"
        delete_comment_via_api(reply_message.source_id, conversation.inbox.channel)
      end

      # Delete the reply message from the system
      Rails.logger.info "[Facebook Moderation] Deleting reply message #{reply_message.id} from system"
      begin
        reply_message.destroy
        Rails.logger.info "[Facebook Moderation] Reply message #{reply_message.id} deleted successfully from system"
      rescue StandardError => e
        Rails.logger.error "[Facebook Moderation] Error deleting reply message #{reply_message.id}: #{e.message}"
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end
  end

  def delete_comment_via_api(comment_id, channel)
    url = "https://graph.facebook.com/v18.0/#{comment_id}"
    params = {
      access_token: channel.page_access_token
    }

    uri = URI(url)
    uri.query = URI.encode_www_form(params)

    Rails.logger.info "[Facebook Moderation] Attempting to delete comment #{comment_id} from Facebook"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Delete.new(uri.request_uri)
    response = http.request(request)

    Rails.logger.info "[Facebook Moderation] Facebook API response: code=#{response.code}, body=#{response.body.inspect}"

    if response.code == '200'
      # Facebook API returns JSON with {"success": true} on successful deletion
      begin
        result = JSON.parse(response.body) rescue {}
        if result['success'] == true || result['success'] == 'true'
          Rails.logger.info "[Facebook Moderation] Comment #{comment_id} deleted successfully from Facebook"
          true
        else
          Rails.logger.warn "[Facebook Moderation] Facebook API returned 200 but success=false for comment #{comment_id}: #{response.body}"
          false
        end
      rescue JSON::ParserError
        # If response is not JSON but code is 200, assume success
        Rails.logger.info "[Facebook Moderation] Comment #{comment_id} deleted successfully (non-JSON response)"
        true
      end
    else
      Rails.logger.error "[Facebook Moderation] Failed to delete comment #{comment_id}: #{response.code} - #{response.body}"
      false
    end
  rescue StandardError => e
    Rails.logger.error "[Facebook Moderation] Error deleting comment: #{e.message}"
    Rails.logger.error(e.backtrace.join("\n"))
    false
  end

  def get_comment_author_id(comment_id, channel)
    url = "https://graph.facebook.com/v18.0/#{comment_id}"
    params = {
      fields: 'from',
      access_token: channel.page_access_token
    }

    uri = URI(url)
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    if response.code == '200'
      data = JSON.parse(response.body) rescue {}
      data.dig('from', 'id')
    else
      Rails.logger.error "[Facebook Moderation] Failed to get comment author: #{response.code} - #{response.body}"
      nil
    end
  rescue StandardError => e
    Rails.logger.error "[Facebook Moderation] Error getting comment author: #{e.message}"
    nil
  end

  def block_user_via_api(user_id, channel)
    # Block user using Facebook Graph API
    # Note: This requires page access token with appropriate permissions
    url = "https://graph.facebook.com/v18.0/#{channel.page_id}/blocked"
    params = {
      user: user_id,
      access_token: channel.page_access_token
    }

    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data(params)
    response = http.request(request)

    if response.code == '200'
      Rails.logger.info "[Facebook Moderation] User #{user_id} blocked successfully"
      true
    else
      Rails.logger.error "[Facebook Moderation] Failed to block user #{user_id}: #{response.code} - #{response.body}"
      false
    end
  rescue StandardError => e
    Rails.logger.error "[Facebook Moderation] Error blocking user: #{e.message}"
    false
  end

  def build_message_attributes(conversation, content, comment_id)
    # Try to find the AgentBot that generated this response
    # The moderation record should have the agent_bot_id if it was generated by a bot
    agent_bot = find_agent_bot_for_moderation

    # Use AgentBot as sender if available, otherwise fall back to a user.
    # CRM-578: the SuperAdmin term between the two is gone. The STI class does not exist
    # here, so it never resolved — and against a legacy row of that type .first raises
    # SubclassNotFound before the `||` runs. User.first is what always chose the sender.
    sender = agent_bot || User.first

    # Build message attributes that will be used to create the message
    # Mark this message as created by moderation approval to prevent reprocessing
    {
      inbox: conversation.inbox,
      content: content,
      message_type: :outgoing,
      sender: sender,
      content_attributes: {
        'in_reply_to_external_id' => comment_id,
        'moderation_approved' => true,
        'moderation_id' => moderation.id.to_s
      }
    }
  end

  def find_agent_bot_for_moderation
    # Try to find the AgentBot that generated this response
    # Use the same logic as AgentBotListener to select the correct bot
    conversation = moderation.conversation
    inbox = conversation.inbox

    # Find AgentBotInbox configuration
    agent_bot_inbox = inbox.agent_bot_inbox
    return nil unless agent_bot_inbox.present?

    # Use agent_bot_for_conversation to get the correct bot (handles comment-specific bots)
    agent_bot = agent_bot_inbox.agent_bot_for_conversation(conversation)

    Rails.logger.info "[Facebook Moderation] Found AgentBot for moderation: #{agent_bot&.name} (ID: #{agent_bot&.id})"
    agent_bot
  rescue StandardError => e
    Rails.logger.warn "[Facebook Moderation] Could not find AgentBot for moderation: #{e.message}"
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end
end

