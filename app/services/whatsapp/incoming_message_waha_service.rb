class Whatsapp::IncomingMessageWahaService < Whatsapp::IncomingMessageBaseService
  def perform
    return if inbox.archived?

    case processed_params[:event]
    when 'message'
      process_message
    when 'session.status'
      process_session_status
    else
      Rails.logger.warn "WAHA: unhandled event type #{processed_params[:event]}"
    end
  end

  private

  def process_message
    payload = (processed_params[:payload] || {}).with_indifferent_access
    return if ActiveModel::Type::Boolean.new.cast(payload[:fromMe])

    # WAHA retries webhook delivery on any non-2xx response (e.g. a transient
    # error, or a rejected HMAC signature during a webhook_hmac_key rollout).
    # Guard against creating a duplicate message for the same WAHA message id,
    # mirroring the find_message_by_source_id dedup used by the other providers
    # (see IncomingMessageBaseService#process_messages / evolution_handlers/messages_upsert.rb).
    return if payload[:id].present? && find_message_by_source_id(payload[:id].to_s)

    set_contact(payload)
    return unless @contact

    set_conversation
    create_message(payload)
  end

  def set_contact(payload)
    # Whatsapp::PhoneNumberNormalizer.call is the single source of truth for turning a raw
    # WAHA chat-id ("5511988887777@c.us") into the canonical digits-only source_id — never a
    # bespoke phone parser here. We compute it once and derive the E.164 phone_number from
    # that same value (rather than calling PhoneNumberNormalizer.to_e164 separately), since
    # to_e164 would otherwise re-run .call on the same raw input.
    source_id = Whatsapp::PhoneNumberNormalizer.call(raw_source_id(payload)) || raw_source_id(payload)
    return if source_id.blank?

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: { phone_number: "+#{source_id}" }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
  end

  def raw_source_id(payload)
    payload[:from].to_s.split('@').first
  end

  def set_conversation
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end
    return if @conversation

    @conversation = ::Conversation.find_or_create_by!(
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    )
  end

  def create_message(payload)
    message = @conversation.messages.build(
      content: payload[:body],
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: payload[:id].to_s
    )
    @message = message
    message.save!
  end

  def process_session_status
    payload = (processed_params[:payload] || {}).with_indifferent_access
    status = payload[:status].to_s

    case status
    when 'WORKING'
      whatsapp_channel.mark_connected!
    when 'SCAN_QR_CODE'
      whatsapp_channel.update_provider_connection!(
        { 'connection' => 'connecting', 'qr_data_url' => payload[:qr], 'error' => nil }.compact
      )
    when 'FAILED', 'STOPPED'
      whatsapp_channel.update_provider_connection!({ 'connection' => 'close', 'error' => status })
    else
      Rails.logger.info "WAHA: session.status #{status} (no channel state change)"
    end
  end

  def whatsapp_channel
    inbox.channel
  end
end
