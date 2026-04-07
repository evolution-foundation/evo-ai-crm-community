class BaseListener
  include Singleton

  def extract_conversation_and_account(event)
    conversation = event.data[:conversation]
    [conversation, single_tenant_account]
  end

  def extract_notification_and_account(event)
    notification = event.data[:notification]
    notification_finder = NotificationFinder.new(notification.user)
    unread_count = notification_finder.unread_count
    count = notification_finder.count
    [notification, single_tenant_account, unread_count, count]
  end

  def extract_message_and_account(event)
    message = event.data[:message]
    [message, single_tenant_account]
  end

  def extract_contact_and_account(event)
    contact = event.data[:contact]
    [contact, single_tenant_account]
  end

  def extract_inbox_and_account(event)
    inbox = event.data[:inbox]
    [inbox, single_tenant_account]
  end

  private

  def single_tenant_account
    RuntimeConfig.account
  end

  def extract_changed_attributes(event)
    changed_attributes = event.data[:changed_attributes]

    return if changed_attributes.blank?

    changed_attributes.map { |k, v| { k => { previous_value: v[0], current_value: v[1] } } }
  end
end
