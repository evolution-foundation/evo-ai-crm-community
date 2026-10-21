# frozen_string_literal: true

# A public acknowledgement has its own durable reservation. Unknown results never replay.
class Instagram::AmhPublicReply
  def self.call(delivery:, explicit_test: false)
    text = reserve(delivery, explicit_test: explicit_test)
    return delivery unless text

    inbox, version, = Instagram::AmhExecutor.eligible!(delivery.inbound_event, delivery.proof.reload, explicit_test: explicit_test)
    raise Instagram::AmhExecutor::Unavailable unless version['id'] == delivery.version_id

    persist(delivery, request(inbox.channel, delivery.inbound_event.contract.fetch('event_id'), text))
  rescue Instagram::AmhExecutor::Unavailable
    delivery.update!(public_reply_state: 'blocked', public_reply_reason: 'rule_unavailable')
    delivery
  rescue StandardError => e
    Rails.logger.error("AMH public reply unavailable: #{e.class}")
    delivery.update!(public_reply_state: 'uncertain', public_reply_reason: 'transport_result_unknown') if delivery.public_reply_state == 'sending'
    delivery
  end

  def self.request(channel, comment, text)
    HTTParty.post("https://graph.instagram.com/v23.0/#{comment}/replies",
                  headers: { 'Authorization' => "Bearer #{channel.access_token}", 'Content-Type' => 'application/json' },
                  body: JSON.generate(message: text), timeout: 20)
  end

  def self.persist(delivery, response)
    body = response.parsed_response
    body = {} unless body.is_a?(Hash)
    accepted = response.success? && body['id'].present?
    state = failure_state(response)
    receipt = accepted ? body.slice('id') : body.fetch('error', {}).slice('code', 'error_subcode', 'type', 'fbtrace_id')
    delivery.update!(public_reply_state: accepted ? 'accepted' : state,
                     public_reply_reason: accepted ? 'provider_accepted' : "provider_#{response.code}",
                     public_reply_accepted_at: accepted ? Time.current : nil,
                     encrypted_public_reply_receipt: Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(receipt))
    delivery
  end

  def self.failure_state(response)
    response.success? || response.code >= 500 ? 'uncertain' : 'failed'
  end

  def self.reserve(delivery, explicit_test:)
    Instagram::AmhVisualProof.with_mapping_lock do
      delivery.with_lock do
        next unless delivery.public_reply_state == 'pending'

        _, version, data, = Instagram::AmhExecutor.eligible!(delivery.inbound_event, delivery.proof.reload, explicit_test: explicit_test)
        reason = blocked_reason(delivery, version, data)
        if reason
          delivery.update!(public_reply_state: 'blocked', public_reply_reason: reason)
          next
        end
        delivery.update!(public_reply_state: 'sending', public_reply_reason: 'reply_reserved', public_reply_requested_at: Time.current)
        data['reply']['publicReplyText']
      end
    end
  end

  def self.blocked_reason(delivery, version, data)
    return 'invitation_not_accepted' unless delivery.prompt_state == 'accepted'
    return 'rule_unavailable' unless version['id'] == delivery.version_id && data['reply']['publicReplyEnabled'] == true
    return 'reply_rate_limited' if Instagram::AmhDelivery.where('public_reply_requested_at > ?', 5.seconds.ago).count >= 40

    nil
  end
  private_class_method :request, :persist, :failure_state, :reserve, :blocked_reason
end
