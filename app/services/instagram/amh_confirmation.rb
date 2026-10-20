# frozen_string_literal: true

# Only verified Meta callbacks carrying our signed payload can release a material.
class Instagram::AmhConfirmation
  class NotReady < StandardError; end
  Unavailable = Instagram::AmhExecutor::Unavailable

  def self.validate!(event, delivery)
    raise Unavailable unless Instagram::AmhExecutor.enabled?

    inbox = Instagram::AmhConnection.bound_inbox!
    proof = delivery.proof.reload
    raise Unavailable unless event.inbox_id == inbox.id && delivery.inbound_event.inbox_id == inbox.id
    raise Unavailable unless inbox.channel.expires_at > Time.current && %w[test active].include?(proof.audience)
    raise Unavailable unless proof.active_version_id == delivery.version_id

    original = delivery.inbound_event.contract
    clicked = event.contract
    raise Unavailable unless clicked['kind'] == 'dm' && %w[quick_reply postback].include?(clicked['confirmation_source'])
    raise Unavailable unless clicked['identity'] == original['identity']
    raise Unavailable if proof.audience == 'test' && !Instagram::AmhExecutor.test_identity?(clicked)

    raise NotReady if delivery.prompt_state == 'sending'
    raise Unavailable unless delivery.prompt_state == 'accepted' && delivery.prompt_expires_at && delivery.prompt_expires_at > Time.current

    clicked_at = Time.iso8601(clicked.fetch('occurred_at'))
    raise Unavailable unless clicked_at > 24.hours.ago && clicked_at <= Time.current && clicked_at >= delivery.created_at - 5.seconds

    version = proof.versions.find { |v| v['id'] == delivery.version_id }
    raise Unavailable unless version

    graph = Instagram::AmhVisualEngine.validate!(version.fetch('graph'))
    data = graph['nodes'].to_h { |node| [node['id'], node['data']] }
    raise Unavailable unless data['reply']['confirmationRequired'] == true

    source = Instagram::AmhExecutor.event_data(original, delivery.inbound_event)
    Instagram::AmhShortLink.validate_event!(source, data)
    [inbox, version, data, source, clicked_at]
  rescue ArgumentError, KeyError, Instagram::AmhShortLink::Unavailable, Instagram::AmhShortLink::Conflict
    raise Unavailable
  end

  def self.call(event:)
    id = Instagram::AmhConfirmationToken.read(event.contract['amh_confirmation'])
    raise Unavailable unless id

    row, inbox, data, link = Instagram::AmhVisualProof.with_mapping_lock do
      delivery = Instagram::AmhDelivery.find_by(id: id)
      raise Unavailable unless delivery

      inbox, version, data, source, clicked_at = validate!(event, delivery)
      next [delivery, nil, nil, nil] unless delivery.state == 'awaiting_confirmation'

      key = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('amh-link-event-v1'),
                                   JSON.generate(source.values_at('account', 'app', 'comment')))
      link = Instagram::AmhShortLink.issue_unique!(key, version, data['material']['material'], source)
      delivery.update!(state: 'sending', reason: 'confirmed_delivery_reserved', confirmation_event_id: event.id,
                       confirmation_received_at: clicked_at)
      [delivery, inbox, data['reply'], link]
    end
    return row unless inbox

    proof = row.proof.reload
    unless Instagram::AmhExecutor.enabled? && proof.active_version_id == row.version_id && %w[test active].include?(proof.audience)
      row.update!(state: 'blocked', reason: 'paused_before_material')
      return row
    end
    result = Instagram::AmhPrivateReply.deliver(channel: inbox.channel, recipient_id: event.contract.dig('identity', 'igsid'),
                                               text: data['text'], url: link.fetch(:url), label: data['buttonLabel'])
    receipt = result.receipt && Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(result.receipt)
    row.update!(state: result.state, reason: result.reason, encrypted_receipt: receipt)
    row
  end
end
