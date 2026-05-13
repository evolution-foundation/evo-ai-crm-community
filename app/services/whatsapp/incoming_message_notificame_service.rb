class Whatsapp::IncomingMessageNotificameService
  include Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  # Map provider status codes to internal message states
  # WhatsApp Cloud and other providers share similar
  # delivery events. Map Notificame codes to the same
  # internal states so the UI behaves consistently.
  STATUS_MAP = {
    'PENDING' => 'sent',
    'SENT' => 'sent',
    'SERVER_ACK' => 'sent',
    'MESSAGE_SENT' => 'sent',
    'DELIVERED' => 'delivered',
    'MESSAGE_DELIVERED' => 'delivered',
    'DELIVERY_ACK' => 'delivered',
    'READ' => 'read',
    'MESSAGE_READ' => 'read',
    'PLAYED' => 'read',
    'ERROR' => 'failed',
    'FAILED' => 'failed'
  }.freeze

  def perform
    case params[:type]
    when 'MESSAGE_STATUS'
      process_status_update
    when 'MESSAGE'
      process_incoming_message if params.dig(:message, :direction) == 'IN'
    end
  rescue StandardError => e
    Rails.logger.error "Notificame processing error: #{e.message}"
  end

  private

  def process_status_update
    provider_id = params.dig(:messageStatus, :providerMessageId).to_s.strip
    decoded_id = decode_nested_base64(provider_id)

    candidate_ids = [provider_id]
    candidate_ids << decoded_id if decoded_id.present?
    candidate_ids.compact!
    candidate_ids.map! do |cid|
      c = cid.to_s.force_encoding('UTF-8')
      c.valid_encoding? ? c : nil
    end
    candidate_ids.compact!

    message = nil
    candidate_ids.each do |cid|
      next if cid.blank?

      message = Message.where("external_source_ids ->> 'notificame_provider_id' = ?", cid).first
      message ||= Message.where("external_source_ids ->> 'notificame' = ?", cid).first
      message ||= Message.find_by(source_id: cid)
      break if message
    end

    message_id = params[:messageId].to_s.strip
    if message.blank? && message_id.present?
      message = Message.where("external_source_ids ->> 'notificame' = ?", message_id).first
      message ||= Message.find_by(source_id: message_id)
    end
    unless message
      Rails.logger.info("Notificame status webhook message not found: #{params[:messageId]}")
      message = inbox.messages.outgoing.order(created_at: :desc).first
      unless message
        Rails.logger.info('No outgoing messages available for status update fallback')
        return
      end
    end

    external_ids = message.external_source_ids || {}
    external_ids['notificame'] ||= message_id if message_id.present?
    external_ids['notificame_provider_id'] ||= provider_id if provider_id.present?
    message.update_column(:external_source_ids, external_ids) if external_ids != message.external_source_ids

    if provider_id.present?
      message.update_column(:source_id, provider_id)
    elsif message.source_id.blank? && message_id.present?
      message.update_column(:source_id, message_id)
    end

    code = params.dig(:messageStatus, :code).to_s.upcase
    has_error = params.dig(:messageStatus, :error).present? || code == 'ERROR'
    status = if has_error
               'failed'
             else
               STATUS_MAP[code] ||
                 (code.include?('DELIVERED') ? 'delivered' : nil) ||
                 (code.include?('READ') ? 'read' : nil) ||
                 (code.include?('SENT') ? 'sent' : 'failed')
             end
    error = if status == 'failed'
              params.dig(:messageStatus, :error, :message) ||
                params.dig(:messageStatus, :message) ||
                params.dig(:messageStatus, :description) ||
                'Failed to send'
            end

    Messages::StatusUpdateService.new(message, status, error).perform

    timestamp_str = params[:timestamp] || params.dig(:messageStatus, :timestamp)
    timestamp = begin
      Time.zone.parse(timestamp_str.to_s)
    rescue StandardError
      Time.current
    end

    if status == 'read'
      conversation = message.conversation
      conversation.update!(contact_last_seen_at: timestamp)
      ::Conversations::UpdateMessageStatusJob.perform_later(conversation.id, timestamp, :read)
    elsif status == 'delivered'
      ::Conversations::UpdateMessageStatusJob.perform_later(message.conversation_id, timestamp, :delivered)
    end
  end

  def process_incoming_message
    msg = params[:message]
    content_data = msg[:contents].first || {}

    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: msg[:from],
      contact_attributes: { name: msg.dig(:visitor, :name), phone_number: "+#{msg[:from]}" }
    ).perform

    conversation = if inbox.lock_to_single_conversation
                     contact_inbox.conversations.last
                   else
                     contact_inbox.conversations.where.not(status: :resolved).last
                   end
    conversation ||= Conversation.create!(conversation_params(contact_inbox))

    raw_provider_id = params[:providerMessageId].to_s.presence ||
                      msg[:providerMessageId].to_s.presence ||
                      content_data[:providerMessageId].to_s.presence

    if content_data[:type] == 'contacts'
      (content_data[:contacts] || []).each do |contact|
        incoming = conversation.messages.new(
          content: message_content(contact),
          inbox_id: inbox.id,
          message_type: :incoming,
          sender: contact_inbox.contact,
          source_id: raw_provider_id.presence || msg[:id]
        )
        handle_reply_and_ids(incoming, conversation, msg, content_data, raw_provider_id)
        attach_contact(incoming, contact)
        incoming.save!
      end
      return
    end

    incoming = conversation.messages.new(
      content: content_data[:text],
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: contact_inbox.contact,
      source_id: raw_provider_id.presence || msg[:id]
    )

    reply_id = msg[:contextProviderMessageId] || msg[:replyProviderMessageId] ||
               msg.dig(:context, :providerMessageId) || msg[:quotedProviderMessageId]
    reply_id ||= msg[:contextMessageId] || msg[:replyMessageId] || msg.dig(:context, :id) || msg[:quotedMessageId]
    reply_id ||= content_data[:contextProviderMessageId] || content_data[:replyProviderMessageId] ||
                 content_data.dig(:context, :providerMessageId) || content_data[:quotedProviderMessageId]
    reply_id ||= content_data[:contextMessageId] || content_data[:replyMessageId] || content_data.dig(:context, :id) || content_data[:quotedMessageId]
    if reply_id.present?
      decoded = decode_nested_base64(reply_id)
      candidate_ids = [reply_id]
      candidate_ids << decoded if decoded.present?
      reply_msg = nil
      candidate_ids.each do |cid|
        reply_msg = conversation.messages.where("external_source_ids ->> 'notificame_provider_id' = ?", cid).first
        reply_msg ||= conversation.messages.where("external_source_ids ->> 'notificame' = ?", cid).first
        reply_msg ||= conversation.messages.find_by(source_id: cid)
        reply_msg ||= Message.where("external_source_ids ->> 'notificame_provider_id' = ?", cid).first
        reply_msg ||= Message.find_by(source_id: cid)
        break if reply_msg
      end

      attrs = incoming.content_attributes.merge(in_reply_to_external_id: reply_id)
      attrs[:in_reply_to] = reply_msg.id if reply_msg
      incoming.assign_attributes(content_attributes: attrs)
      if reply_msg && reply_id.present?
        external_ids = reply_msg.external_source_ids || {}
        if external_ids['notificame_provider_id'].blank?
          external_ids['notificame_provider_id'] = reply_id
          reply_msg.update_column(:external_source_ids, external_ids)
        end
        reply_msg.update_column(:source_id, reply_id) if reply_msg.source_id.blank?
      end
    end

    message_id = msg[:id].to_s
    if raw_provider_id.present?
      external_ids = incoming.external_source_ids || {}
      external_ids['notificame'] ||= message_id if message_id.present?
      external_ids['notificame_provider_id'] ||= raw_provider_id
      incoming.external_source_ids = external_ids
      incoming.source_id = raw_provider_id
    elsif message_id.present?
      external_ids = incoming.external_source_ids || {}
      external_ids['notificame'] ||= message_id
      incoming.external_source_ids = external_ids
      incoming.source_id ||= message_id
    end

    attach_file(incoming, content_data) if content_data[:fileUrl].present?
    attach_location(incoming, content_data) if content_data[:type] == 'location'
    incoming.save!
  end

  def handle_reply_and_ids(message, conversation, msg, content_data, raw_provider_id)
    reply_id = msg[:contextProviderMessageId] || msg[:replyProviderMessageId] ||
               msg.dig(:context, :providerMessageId) || msg[:quotedProviderMessageId]
    reply_id ||= msg[:contextMessageId] || msg[:replyMessageId] || msg.dig(:context, :id) || msg[:quotedMessageId]
    reply_id ||= content_data[:contextProviderMessageId] || content_data[:replyProviderMessageId] ||
                 content_data.dig(:context, :providerMessageId) || content_data[:quotedProviderMessageId]
    reply_id ||= content_data[:contextMessageId] || content_data[:replyMessageId] || content_data.dig(:context, :id) || content_data[:quotedMessageId]
    if reply_id.present?
      decoded = decode_nested_base64(reply_id)
      candidate_ids = [reply_id]
      candidate_ids << decoded if decoded.present?
      reply_msg = nil
      candidate_ids.each do |cid|
        reply_msg = conversation.messages.where("external_source_ids ->> 'notificame_provider_id' = ?", cid).first
        reply_msg ||= conversation.messages.where("external_source_ids ->> 'notificame' = ?", cid).first
        reply_msg ||= conversation.messages.find_by(source_id: cid)
        reply_msg ||= Message.where("external_source_ids ->> 'notificame_provider_id' = ?", cid).first
        reply_msg ||= Message.find_by(source_id: cid)
        break if reply_msg
      end

      attrs = message.content_attributes.merge(in_reply_to_external_id: reply_id)
      attrs[:in_reply_to] = reply_msg.id if reply_msg
      message.assign_attributes(content_attributes: attrs)
      if reply_msg && reply_id.present?
        external_ids = reply_msg.external_source_ids || {}
        if external_ids['notificame_provider_id'].blank?
          external_ids['notificame_provider_id'] = reply_id
          reply_msg.update_column(:external_source_ids, external_ids)
        end
        reply_msg.update_column(:source_id, reply_id) if reply_msg.source_id.blank?
      end
    end

    message_id = msg[:id].to_s
    if raw_provider_id.present?
      external_ids = message.external_source_ids || {}
      external_ids['notificame'] ||= message_id if message_id.present?
      external_ids['notificame_provider_id'] ||= raw_provider_id
      message.external_source_ids = external_ids
      message.source_id = raw_provider_id
    elsif message_id.present?
      external_ids = message.external_source_ids || {}
      external_ids['notificame'] ||= message_id
      message.external_source_ids = external_ids
      message.source_id ||= message_id
    end
  end

  def attach_contact(message, contact)
    phones = contact_phones(contact)
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    phones.each do |phone|
      message.attachments.new(
        file_type: file_content_type('contacts'),
        fallback_title: phone[:phone].to_s,
        meta: { display_name: contact.dig(:name, :formatted_name) || contact[:displayName] || contact[:display_name] }
      )
    end
  end

  def conversation_params(contact_inbox)
    {
      inbox_id: inbox.id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id
    }
  end

  def attach_file(message, content)
    mime_type = content[:fileMimeType].to_s
    file_type_key = mime_type.split('/').first
    response = inbox.channel.provider_service.download_media(content[:fileUrl], mime_type)

    if response&.success?
      ext = MIME::Types[mime_type].first&.preferred_extension
      ext = ext.present? ? ".#{ext}" : File.extname(content[:fileUrl])
      tempfile = Tempfile.new(['notificame', ext])
      tempfile.binmode
      tempfile.write(response.body)
      tempfile.rewind
      io = tempfile
    else
      Rails.logger.warn "Notificame download failed with #{response&.code}, trying direct download"
      io = Down.download(content[:fileUrl])
    end

    message.attachments.new(
      file_type: file_content_type(file_type_key),
      fallback_title: (File.basename(URI.parse(content[:fileUrl].to_s).path) rescue File.basename(content[:fileUrl].to_s)).presence,
      file: { io: io, filename: File.basename(io.path), content_type: mime_type }
    )

  rescue StandardError => e
    Rails.logger.error "Notificame file attach error: #{e.message}"
  end

  def attach_location(message, content)
    location_name = if content[:name].present?
                      [content[:name], content[:address]].reject(&:blank?).join(', ')
                    else
                      ''
                    end
    message.attachments.new(
      file_type: :location,
      coordinates_lat: content[:latitude],
      coordinates_long: content[:longitude],
      fallback_title: location_name,
      external_url: content[:url]
    )
  end

  def decode_nested_base64(str)
    return nil if str.blank?

    decoded = str.to_s
    2.times do
      temp = Base64.decode64(decoded)
      break if temp.blank? || temp == decoded

      decoded = temp
    rescue StandardError
      break
    end
    decoded.force_encoding('UTF-8')
    decoded.valid_encoding? ? decoded : nil
  end
end
