# This Builder will create a contact and contact inbox with specified attributes.
# If an existing identified contact exisits, it will be returned.
# for contact inbox logic it uses the contact inbox builder

class ContactInboxWithContactBuilder
  pattr_initialize [:inbox!, :contact_attributes!, :source_id, :hmac_verified]

  def perform
    find_or_create_contact_and_contact_inbox
  # in case of race conditions where contact is created by another thread
  # we will try to find the contact and create a contact inbox
  rescue ActiveRecord::RecordNotUnique
    find_or_create_contact_and_contact_inbox
  end

  def find_or_create_contact_and_contact_inbox
    # For channels without phone-format drift between normalizers (Cloud API,
    # Instagram, Web Widget, ...), use the simple source_id lookup
    unless reconcilable_whatsapp_channel?
      @contact_inbox = inbox.contact_inboxes.find_by(source_id: source_id) if source_id.present?
      # BSUID fallback: if source_id lookup failed and source_id looks like a BSUID,
      # try finding by bsuid column (contact was previously created with phone as source_id)
      if @contact_inbox.nil? && whatsapp_cloud_channel? && source_id.present? && source_id.match?(RegexHelper::BSUID_REGEX)
        @contact_inbox = inbox.contact_inboxes.find_by(bsuid: source_id)
      end
      return @contact_inbox if @contact_inbox
    end

    # Evolution Go and Evolution API (non-official) can see the same contact
    # arrive with a slightly different source_id than what's already stored
    # (e.g. manual CRM creation vs. inbound webhook disagreeing on the nono
    # dígito). Do a smart search that reuses the contact's existing
    # ContactInbox on this inbox instead of creating a duplicate.
    if reconcilable_whatsapp_channel?
      Rails.logger.info "#{inbox.channel.provider}: Smart contact/inbox lookup for source_id: #{source_id}"
      perform_smart_whatsapp_lookup
      return @contact_inbox if @contact_inbox
    end

    ActiveRecord::Base.transaction(requires_new: true) do
      build_contact_with_contact_inbox
    end

    update_contact_avatar(@contact) unless @contact.avatar.attached?
    @contact_inbox
  end

  def reconcilable_whatsapp_channel?
    inbox.channel_type == 'Channel::Whatsapp' && inbox.channel.provider.in?(%w[evolution_go evolution waha])
  end

  private

  def perform_smart_whatsapp_lookup
    # First check if ContactInbox with this exact source_id already exists
    @contact_inbox = inbox.contact_inboxes.find_by(source_id: source_id) if source_id.present?
    if @contact_inbox
      Rails.logger.info "#{inbox.channel.provider}: Found existing ContactInbox #{@contact_inbox.id} with exact source_id '#{source_id}'"
      @contact = @contact_inbox.contact
      return
    end

    # If not found by source_id, try to find contact by attributes
    @contact = find_contact
    if @contact
      # Always check if this contact already has a ContactInbox in this inbox
      existing_contact_inbox = find_existing_contact_inbox_for_reconciliation(@contact)
      if existing_contact_inbox
        Rails.logger.info "#{inbox.channel.provider}: Contact #{@contact.id} already has ContactInbox #{existing_contact_inbox.id} (source_id: '#{existing_contact_inbox.source_id}')"
        Rails.logger.info "#{inbox.channel.provider}: Updating to new source_id '#{source_id}' - REUSING existing ContactInbox"
        existing_contact_inbox.update!(source_id: source_id)
        @contact_inbox = existing_contact_inbox
        return
      end
    end

    # If no contact found or contact has no ContactInbox in this inbox, will create new ones
    Rails.logger.info "#{inbox.channel.provider}: No existing ContactInbox found for source_id '#{source_id}' - will create new contact/inbox"
  end

  def build_contact_with_contact_inbox
    @contact = find_contact || create_contact
    # Update identifier if contact doesn't have one but contact_attributes provides it
    if @contact.identifier.blank? && contact_attributes[:identifier].present?
      @contact.update!(identifier: contact_attributes[:identifier])
    end
    # Only create contact_inbox if not already found in find_contact (for Evolution Go)
    @contact_inbox ||= create_contact_inbox
  end

  def create_contact_inbox
    ContactInboxBuilder.new(
      contact: @contact,
      inbox: @inbox,
      source_id: @source_id,
      hmac_verified: hmac_verified
    ).perform
  end

  def update_contact_avatar(contact)
    return unless contact_attributes[:avatar_url]

    ::Avatar::AvatarFromUrlJob.perform_later(contact, contact_attributes[:avatar_url])
  end

  def create_contact
    contact = Contact.new(
      name: contact_attributes[:name] || ::Haikunator.haikunate(1000),
      phone_number: contact_attributes[:phone_number],
      email: contact_attributes[:email],
      identifier: contact_attributes[:identifier],
      additional_attributes: contact_attributes[:additional_attributes],
      custom_attributes: contact_attributes[:custom_attributes],
      location: contact_attributes[:location] || '', # Ensure location is never nil
      country_code: contact_attributes[:country_code] || '', # Ensure country_code is never nil
      type: contact_attributes[:type] || 'person'
    )

    # Contacts created via inbox/channel flows are usually followed by conversation creation.
    # Avoid creating duplicate default pipeline items (contact + conversation) for the same flow.
    contact.skip_default_pipeline_assignment = true
    contact.save!
    contact
  end

  def find_contact
    contact = find_contact_by_identifier(contact_attributes[:identifier])
    contact ||= find_contact_by_email(contact_attributes[:email])
    contact ||= find_contact_by_phone_number(contact_attributes[:phone_number])
    contact ||= find_contact_by_instagram_source_id(source_id) if instagram_channel?

    contact
  end

  def instagram_channel?
    inbox.channel_type == 'Channel::Instagram'
  end

  def whatsapp_cloud_channel?
    inbox.channel_type == 'Channel::Whatsapp' && inbox.channel.provider == 'whatsapp_cloud'
  end

  def find_existing_contact_inbox_for_reconciliation(contact)
    return nil unless contact

    # Find any existing ContactInbox for this contact in this inbox
    contact.contact_inboxes.find_by(inbox: inbox)
  end

  # There might be existing contact_inboxes created through Channel::FacebookPage
  # with the same Instagram source_id. New Instagram interactions should create fresh contact_inboxes
  # while still reusing contacts if found in Facebook channels so that we can create
  # new conversations with the same contact.
  def find_contact_by_instagram_source_id(instagram_id)
    return if instagram_id.blank?

    existing_contact_inbox = ContactInbox.joins(:inbox)
                                         .where(source_id: instagram_id)
                                         .where(
                                           'inboxes.channel_type = ?',
                                           'Channel::FacebookPage'
                                         ).first

    existing_contact_inbox&.contact
  end

  def find_contact_by_identifier(identifier)
    return if identifier.blank?

    Contact.find_by(identifier: identifier)
  end

  def find_contact_by_email(email)
    return if email.blank?

    Contact.from_email(email)
  end

  def find_contact_by_phone_number(phone_number)
    return if phone_number.blank?

    # Normalize the lookup key to the canonical stored form so a contact created
    # via another path (e.g. leads API) is matched instead of duplicated.
    normalized = Whatsapp::PhoneNumberNormalizer.to_e164(phone_number)
    return if normalized.blank?

    Contact.find_by(phone_number: normalized)
  end
end
