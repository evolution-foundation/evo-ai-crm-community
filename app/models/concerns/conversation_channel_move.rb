# frozen_string_literal: true

# Rule for whether a conversation can be manually moved to a different inbox
# (the "Change channel" action). Kept as its own concern rather than inline
# in Conversation, which is already large — see app/models/conversation.rb.
module ConversationChannelMove
  extend ActiveSupport::Concern

  def eligible_move_target?(target_inbox)
    return false if target_inbox.archived?
    return false if target_inbox.web_widget?
    return true if target_inbox.channel_type == inbox.channel_type

    case target_inbox.channel_type
    when 'Channel::Whatsapp'
      contact.phone_number.present?
    when 'Channel::Email'
      contact.email.present?
    else
      false
    end
  end
end
