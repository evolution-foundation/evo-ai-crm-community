class Instagram::BaseMessageText < Instagram::WebhooksBaseService
  attr_reader :messaging

  def initialize(messaging, channel)
    @messaging = messaging
    super(channel)
  end

  def perform
    connected_instagram_id, contact_id = instagram_and_contact_ids
    Rails.logger.info("[Instagram::BaseMessageText] Starting perform - connected_instagram_id: #{connected_instagram_id}, contact_id: #{contact_id}")

    inbox_channel(connected_instagram_id)
    Rails.logger.info("[Instagram::BaseMessageText] Inbox found: #{@inbox.inspect}")

    if @inbox.blank?
      Rails.logger.warn("[Instagram::BaseMessageText] Inbox is blank, skipping message processing")
      return
    end

    return unless Instagram::AmhSafety.reception_enabled?(@inbox)

    if @inbox.channel.reauthorization_required?
      Rails.logger.info("[Instagram::BaseMessageText] Skipping message processing as reauthorization is required for inbox #{@inbox.id}")
      return
    end

    if message_is_deleted?
      Rails.logger.info("[Instagram::BaseMessageText] Message is deleted, calling unsend_message")
      return unsend_message
    end

    is_first_message = contacts_first_message?(contact_id)
    Rails.logger.info("[Instagram::BaseMessageText] contacts_first_message?(#{contact_id}): #{is_first_message}, contact_inbox: #{@contact_inbox.inspect}")

    if is_first_message
      Rails.logger.info("[Instagram::BaseMessageText] First message from contact, ensuring contact exists")
      ensure_contact(contact_id)
      Rails.logger.info("[Instagram::BaseMessageText] After ensure_contact, contact_inbox: #{@contact_inbox.inspect}")
    elsif !@contact_inbox.contact.avatar.attached?
      Rails.logger.info("[Instagram::BaseMessageText] Contact avatar missing, refreshing Instagram profile")
      ensure_contact(contact_id)
    end

    # Ensure contact_inbox is set even if it wasn't found in contacts_first_message?
    if @contact_inbox.blank?
      Rails.logger.warn("[Instagram::BaseMessageText] contact_inbox is blank, attempting to find it again")
      @contact_inbox = @inbox.contact_inboxes.where(source_id: contact_id).last
      Rails.logger.info("[Instagram::BaseMessageText] After re-finding contact_inbox: #{@contact_inbox.inspect}")
    end

    if @contact_inbox.blank?
      Rails.logger.error("[Instagram::BaseMessageText] contact_inbox is still blank, cannot create message. contact_id: #{contact_id}, inbox_id: #{@inbox.id}")
      return
    end

    Rails.logger.info("[Instagram::BaseMessageText] Calling create_message with contact_inbox: #{@contact_inbox.id}")
    result = create_message
    Rails.logger.info("[Instagram::BaseMessageText] create_message result: #{result.inspect}")
    result
  end

  private

  def instagram_and_contact_ids
    if agent_message_via_echo?
      [@messaging[:sender][:id], @messaging[:recipient][:id]]
    else
      [@messaging[:recipient][:id], @messaging[:sender][:id]]
    end
  end

  def agent_message_via_echo?
    @messaging[:message][:is_echo].present?
  end

  def message_is_deleted?
    @messaging[:message][:is_deleted].present?
  end

  # if contact was present before find out contact_inbox to create message
  def contacts_first_message?(ig_scope_id)
    @contact_inbox = @inbox.contact_inboxes.where(source_id: ig_scope_id).last
    result = @contact_inbox.blank? && @inbox.channel.instagram_id.present?
    Rails.logger.info("[Instagram::BaseMessageText] contacts_first_message?(#{ig_scope_id}): #{result} - contact_inbox found: #{@contact_inbox.present?}, channel.instagram_id: #{@inbox.channel.instagram_id.present?}")
    result
  end

  def unsend_message
    message_to_delete = @inbox.messages.find_by(
      source_id: @messaging[:message][:mid]
    )
    return if message_to_delete.blank?

    message_to_delete.attachments.destroy_all
    message_to_delete.update!(content: I18n.t('conversations.messages.deleted'), deleted: true)
  end

  # Methods to be implemented by subclasses
  def ensure_contact(contact_id)
    raise NotImplementedError, "#{self.class} must implement #ensure_contact"
  end

  def create_message
    raise NotImplementedError, "#{self.class} must implement #create_message"
  end
end
