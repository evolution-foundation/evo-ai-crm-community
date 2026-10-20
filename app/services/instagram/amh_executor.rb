# frozen_string_literal: true

# Durable, per-comment reservation; crashed/uncertain sends are never retried.
class Instagram::AmhExecutor
  class Unavailable < StandardError; end

  def self.enabled?
    ENV['INSTAGRAM_AMH_EXECUTION_ENABLED'] == 'true' && ENV['INSTAGRAM_AMH_LINK_QA_ENABLED'] == 'true'
  end

  def self.test_identity?(contract)
    ENV.fetch('INSTAGRAM_AMH_TEST_IGSIDS', '').split(',').map(&:strip).reject(&:empty?).include?(contract.dig('identity', 'igsid'))
  end

  def self.event_data(contract, event)
    { 'account' => contract.dig('identity', 'professional_account_id'), 'app' => contract.dig('identity', 'app_id'),
      'comment' => contract['event_id'], 'text' => contract['comment_text'], 'ad' => contract['ad_id'],
      'media' => contract['media_id'], 'inbound_event_id' => event.id }.compact
  end

  def self.eligible!(event, proof, explicit_test: false)
    raise Unavailable unless enabled?

    inbox = Instagram::AmhConnection.bound_inbox!
    raise Unavailable unless event.inbox_id == inbox.id && inbox.channel.expires_at > Time.current

    contract = event.contract
    raise Unavailable unless contract['kind'] == 'comment' && contract.dig('identity', 'app_id') == Instagram::AmhConnection.app_id
    raise Unavailable unless contract.dig('identity', 'professional_account_id') == inbox.channel.instagram_id
    raise Unavailable if contract['live'] == true || contract['time_source'] != 'webhook_entry'
    raise Unavailable unless proof.active_version_id && %w[test active].include?(proof.audience)
    raise Unavailable if (explicit_test || proof.audience == 'test') && !test_identity?(contract)

    occurred = Time.iso8601(contract.fetch('occurred_at'))
    raise Unavailable unless occurred > 7.days.ago && occurred <= Time.current
    raise Unavailable if !explicit_test && occurred < proof.activated_at

    version = proof.versions.find { |v| v['id'] == proof.active_version_id }
    raise Unavailable unless version

    graph = Instagram::AmhVisualEngine.validate!(version.fetch('graph'))
    data = graph.fetch('nodes').to_h { |node| [node['id'], node['data']] }
    payload = event_data(contract, event)
    Instagram::AmhShortLink.validate_event!(payload, data)
    [inbox, version, data, payload]
  rescue ArgumentError, KeyError, Instagram::AmhShortLink::Unavailable, Instagram::AmhShortLink::Conflict
    raise Unavailable
  end

  def self.call(event:, proof:, explicit_test: false)
    # Hold mapping lock through reservation, not during the external request.
    delivery, inbox, text = Instagram::AmhVisualProof.with_mapping_lock do
      proof.reload
      inbox, version, data, payload = eligible!(event, proof, explicit_test: explicit_test)
      candidates = Instagram::AmhVisualProof.where(audience: %w[test active]).filter_map do |candidate|
        next if candidate.id == proof.id
        begin
          eligible!(event, candidate, explicit_test: explicit_test)
          candidate.id
        rescue Unavailable
          nil
        end
      end
      raise Unavailable if candidates.any?

      row = Instagram::AmhDelivery.create_or_find_by!(inbound_event_id: event.id) do |record|
        record.proof = proof
        record.version_id = version['id']
      end
      next [row, nil, nil] unless row.state == 'pending'
      raise Unavailable unless row.proof_id == proof.id && row.version_id == version['id']

      key = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('amh-link-event-v1'),
                                   JSON.generate(payload.values_at('account', 'app', 'comment')))
      link = Instagram::AmhShortLink.issue_unique!(key, version, data['material']['material'], payload)
      row.update!(state: 'sending', reason: 'reserved_no_automatic_retry')
      [row, inbox, data['reply']['text'].gsub('{{link}}', link.fetch(:url))]
    end
    return delivery unless inbox

    # Recheck operational gates immediately before crossing the transport boundary.
    unless enabled? && proof.reload.active_version_id == delivery.version_id && %w[test active].include?(proof.audience)
      delivery.update!(state: 'blocked', reason: 'paused_before_send')
      return delivery
    end
    result = Instagram::AmhPrivateReply.call(channel: inbox.channel, comment_id: event.contract['event_id'], text: text)
    receipt = result.receipt && Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(result.receipt)
    delivery.update!(state: result.state, reason: result.reason, encrypted_receipt: receipt)
    delivery
  end
end
