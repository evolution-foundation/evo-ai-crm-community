class NotificationBuilder
  pattr_initialize [:notification_type!, :user!, :account, :primary_actor!, :secondary_actor]

  def perform
    build_notification
  end

  private

  def current_user
    Current.user
  end

  def user_subscribed_to_notification?
    notification_setting = user.notification_settings.first
    # added for the case where an assignee might be removed but remains in conversation
    return false if notification_setting.blank?

    return true if notification_setting.public_send("email_#{notification_type}?")
    return true if notification_setting.public_send("push_#{notification_type}?")

    false
  end

  def build_notification
    # Create conversation_creation notification only if user is subscribed to it
    return if notification_type == 'conversation_creation' && !user_subscribed_to_notification?
    # skip notifications for blocked conversations
    return if primary_actor.contact.blocked?

    user.notifications.create!(
      notification_type: notification_type,
      primary_actor: primary_actor,
      # secondary_actor is secondary_actor if present, else current_user
      secondary_actor: secondary_actor || current_user
    )
  end
end
