# Status-only payloads never create empty messages. Redis retention is bounded.
class Whatsapp::ObservedStatusService
  TTL = 24.hours
  RANK = { 'sent' => 1, 'delivered' => 2, 'read' => 3, 'failed' => 4 }.freeze

  def initialize(inbox)
    @inbox = inbox
  end

  def receive(status, contacts = [])
    status = status.with_indifferent_access.merge(contacts: contacts)
    return unless status[:id].present? && RANK.key?(status[:status])

    message = @inbox.messages.find_by(source_id: status[:id])
    return apply(message, status) if message

    key = cache_key(status[:id])
    old = Rails.cache.read(key)
    return if old && (%w[read failed].include?(old['status']) || RANK.fetch(old['status'], 0) >= RANK.fetch(status[:status]))

    Rails.cache.write(key, status.slice(:id, :status, :errors, :recipient_user_id, :contacts).deep_stringify_keys, expires_in: TTL)
  end

  def reconcile(id)
    status = Rails.cache.read(cache_key(id))
    return unless status

    message = @inbox.messages.find_by(source_id: id)
    return unless message

    apply(message, status.with_indifferent_access)
    # Keep until TTL: a surrounding transaction can still roll back.
  end

  private

  def apply(message, status)
    contact = Array(status[:contacts]).first || {}
    contact_inbox = message.conversation.contact_inbox
    identity = { bsuid: status[:recipient_user_id].presence || contact[:user_id],
                 whatsapp_username: contact.dig(:profile, :username) }.compact_blank
    contact_inbox.update!(identity) if contact_inbox && identity.present?
    error = Array(status[:errors]).first
    external_error = error && status[:status] == 'failed' ? "#{error[:code]}: #{error[:title]}".truncate(255) : nil
    if message.whatsapp_observed?
      return if %w[read failed].include?(message.status)
      return if RANK.fetch(message.status, 0) >= RANK.fetch(status[:status])

      attrs = { status: status[:status] }
      attrs[:content_attributes] = message.content_attributes.merge(external_error: external_error) if external_error
      message.update!(attrs)
    else
      Messages::StatusUpdateService.new(message, status[:status], external_error).perform
    end
  end

  def cache_key(id)
    "whatsapp:pending-status:#{@inbox.id}:#{Digest::SHA256.hexdigest(id.to_s)}"
  end
end
