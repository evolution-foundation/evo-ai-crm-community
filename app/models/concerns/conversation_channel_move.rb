# frozen_string_literal: true

# Rule for whether a conversation can be manually moved to a different inbox
# (the "Change channel" action). Kept as its own concern rather than inline
# in Conversation, which is already large — see app/models/conversation.rb.
module ConversationChannelMove
  extend ActiveSupport::Concern

  def eligible_move_target?(target_inbox)
    return false if target_inbox.archived?
    return false if target_inbox.web_widget?
    # A move always runs ContactInboxBuilder against the target, and that
    # builder can only derive a source_id for the channel types listed in its
    # own #generate_source_id. For anything else (Telegram, Line,
    # TwitterProfile, Instagram) it raises mid-transaction, which
    # move_channel does not rescue — a 500 instead of a clean 422. For the
    # types it DOES support, some (email/sms/twilio/whatsapp) still need a
    # matching contact identifier or the builder raises
    # ActionController::ParameterMissing instead (same-type Sourcery finding,
    # PR #373); others (api/facebook_page) generate a random UUID and need
    # nothing from the contact.
    return same_type_move_eligible?(target_inbox) if target_inbox.channel_type == inbox.channel_type

    case target_inbox.channel_type
    when 'Channel::Whatsapp'
      contact.phone_number.present?
    when 'Channel::Email'
      contact.email.present?
    else
      false
    end
  end

  private

  def same_type_move_eligible?(target_inbox)
    return true if target_inbox.api? || target_inbox.facebook?
    return contact.email.present? if target_inbox.email?
    return contact.phone_number.present? if target_inbox.sms? || target_inbox.twilio? || target_inbox.whatsapp?

    false
  end
end
