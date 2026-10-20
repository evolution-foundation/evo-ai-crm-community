# frozen_string_literal: true

# Scoped operational pause. Read on every producer/consumer invocation so queued
# work cannot retain an earlier permission. Never infer scope from username/PII.
class Instagram::AmhSafety
  class << self
    def inbox_ids
      ENV.fetch('INSTAGRAM_AMH_INBOX_IDS', '').split(',').map(&:strip).reject(&:empty?)
    end

    def reception_enabled?(inbox)
      !inbox || inbox_ids.exclude?(inbox.id.to_s) || ENV.fetch('INSTAGRAM_AMH_RECEPTION_ENABLED', 'true') == 'true'
    end

    def blocked_inbox?(inbox)
      return false unless inbox && inbox_ids.include?(inbox.id.to_s)

      # Deliberately no outbound opt-in in this release. Activation is a separate
      # reviewed change; reception and manual replies continue independently.
      audit('inbox')
      true
    end

    def blocked_contact?(contact)
      return false unless contact && !inbox_ids.empty?
      return false unless contact.contact_inboxes.exists?(inbox_id: inbox_ids)

      audit('contact')
      true
    end

    def blocked_message?(message)
      return false unless message.inbox && inbox_ids.include?(message.inbox.id.to_s)
      return false unless message.outgoing? || message.template?

      # Only a human sender without automation provenance can pass.
      # A client-provided boolean such as manual=true is never an exemption.
      return false if manual_message?(message)

      audit('message')
      true
    end

    def blocked_payload?(payload)
      return false if inbox_ids.empty?

      data = payload.with_indifferent_access
      id = payload_inbox_id(data)
      return audit('payload') if id && inbox_ids.include?(id.to_s)

      # Contact-only automation payloads have no inbox. Look up their durable
      # contact-inbox mapping; do not use display_id as a globally unique UUID.
      return blocked_contact?(Contact.find_by(id: data[:contactId])) if data[:contactId]
      return blocked_contact?(Contact.find_by(id: data[:id])) if data[:event].to_s.start_with?('contact_')

      false
    end

    private

    def manual_message?(message)
      attributes = message.content_attributes || {}
      additional = message.additional_attributes || {}
      message.sender.is_a?(User) && attributes['automation_rule_id'].blank? && additional['campaign_id'].blank?
    end

    def payload_inbox_id(data)
      data[:inbox_id] || data.dig(:inbox, :id) || data.dig(:conversation, :inbox_id) || data.dig(:metadata, :inboxId)
    end

    def audit(boundary)
      Rails.logger.info("[InstagramAmhSafety] blocked automated outbound boundary=#{boundary}")
      true
    end
  end
end
