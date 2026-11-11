module Whatsapp::EvolutionHandlers::ContentHandlers
  def handle_location
    location_msg = @raw_message.dig(:message, :locationMessage)
    return unless location_msg

    @message.content_attributes[:location] = {
      latitude: location_msg[:degreesLatitude],
      longitude: location_msg[:degreesLongitude],
      name: location_msg[:name],
      address: location_msg[:address]
    }
  end

  def handle_contacts
    contact_msg = @raw_message.dig(:message, :contactMessage)
    contacts_array = @raw_message.dig(:message, :contactsArrayMessage, :contacts)

    contacts = if contact_msg
                 [contact_msg]
               elsif contacts_array
                 contacts_array
               else
                 []
               end

    @message.content_attributes[:contacts] = contacts.map do |contact|
      {
        display_name: contact[:displayName],
        vcard: contact[:vcard]
      }
    end

    contacts.each { |contact| attach_contact(contact) }
  end

  # Evolution API (baileys) only sends the raw vCard string, unlike Z-API/Cloud API
  # which already provide structured phone arrays — so we parse TEL lines ourselves.
  # One Attachment (file_type: :contact) is created per phone, matching the pattern
  # used by Whatsapp::IncomingMessageBaseService#attach_contact and
  # Whatsapp::IncomingMessageZapiService#attach_contact.
  def attach_contact(contact)
    display_name = contact[:displayName] || vcard_field(contact[:vcard], 'FN')
    phones = vcard_phone_numbers(contact[:vcard])
    phones = ['Phone number is not available'] if phones.blank?

    phones.each do |phone|
      @message.attachments.build(
        file_type: file_content_type.to_s,
        fallback_title: phone,
        meta: { display_name: display_name }
      )
    end
  end

  def vcard_phone_numbers(vcard)
    return [] if vcard.blank?

    vcard.to_s.each_line.filter_map do |line|
      match = line.match(/^TEL[^:]*:(.+)$/i)
      match && match[1].strip.presence
    end
  end

  def vcard_field(vcard, field)
    vcard.to_s.match(/#{field}:(.+)/i)&.[](1)&.strip
  end

  def message_content_attributes
    content_attributes = {
      external_created_at: evolution_extract_message_timestamp(@raw_message[:messageTimestamp])
    }

    if message_type == 'reaction'
      content_attributes[:in_reply_to_external_id] = @raw_message.dig(:message, :reactionMessage, :key, :id)
      content_attributes[:is_reaction] = true
    elsif message_type == 'unsupported'
      content_attributes[:is_unsupported] = true
    end

    content_attributes[:sender_name] = participant_push_name if jid_type == 'group' && participant_push_name.present?
    content_attributes[:media_type] = message_type if media_attachment?

    content_attributes
  end
end
