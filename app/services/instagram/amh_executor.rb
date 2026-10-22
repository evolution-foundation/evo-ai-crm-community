# frozen_string_literal: true

# Comments reserve and send only an invitation. A material link cannot be issued here.
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

  def self.eligible!(event, proof, explicit_test: false, resolve_material: true)
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
    raise Unavailable unless data['reply']['confirmationRequired'] == true

    payload = event_data(contract, event)
    Instagram::AmhShortLink.validate_event!(payload, data)
    if resolve_material
      material, source = Instagram::AmhContextRouter.resolve(event, data['material'], version)
      data = data.deep_dup
      data['material'] = data['material'].merge('material' => material, 'routingSource' => source)
    end
    [inbox, version, data, payload]
  rescue ArgumentError, KeyError, Instagram::AmhShortLink::Unavailable, Instagram::AmhShortLink::Conflict
    raise Unavailable
  end

  def self.call(event:, proof:, explicit_test: false)
    prepare_context!(event, proof, explicit_test: explicit_test)
    delivery, inbox, opening = Instagram::AmhVisualProof.with_mapping_lock do
      proof.reload
      inbox, version, data, = eligible!(event, proof, explicit_test: explicit_test)
      ambiguous = Instagram::AmhVisualProof.where(audience: %w[test active]).any? do |candidate|
        next false if candidate.id == proof.id

        begin
          eligible!(event, candidate, explicit_test: explicit_test, resolve_material: false)
          true
        rescue Unavailable
          false
        end
      end
      raise Unavailable if ambiguous

      row = Instagram::AmhDelivery.create_or_find_by!(inbound_event_id: event.id) do |record|
        record.proof = proof
        record.version_id = version['id']
        record.resolved_material = data['material']['material']
        record.routing_source = data['material']['routingSource']
        record.like_state = 'pending'
        record.public_reply_state = data['reply']['publicReplyEnabled'] == true ? 'pending' : 'not_requested'
      end
      # Historical direct deliveries and terminal/abandoned invitations never replay.
      next [row, nil, nil] unless row.state == 'pending' && row.prompt_state == 'pending'

      raise Unavailable unless row.proof_id == proof.id && row.version_id == version['id']

      row.update!(state: 'prompt_sending', prompt_state: 'sending', reason: 'invitation_reserved')
      [row, inbox, data['reply']['openingText']]
    end
    return finish_like(delivery, explicit_test: explicit_test) unless inbox

    unless enabled? && proof.reload.active_version_id == delivery.version_id && %w[test active].include?(proof.audience)
      delivery.update!(state: 'blocked', prompt_state: 'blocked', reason: 'paused_before_invitation')
      return delivery
    end
    result = Instagram::AmhPrivateReply.prompt(channel: inbox.channel, comment_id: event.contract['event_id'],
                                               text: Instagram::AmhInvitation.render(text: opening, contract: event.contract, inbox: inbox),
                                               payload: Instagram::AmhConfirmationToken.issue(delivery))
    accepted = result.state == 'accepted'
    receipt = result.receipt && Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(result.receipt)
    delivery.update!(state: accepted ? 'awaiting_confirmation' : "prompt_#{result.state}", prompt_state: result.state,
                     reason: accepted ? 'waiting_for_button_click' : result.reason, encrypted_prompt_receipt: receipt,
                     prompt_accepted_at: accepted ? Time.current : nil, prompt_expires_at: accepted ? 7.days.from_now : nil)
    finish_like(delivery, explicit_test: explicit_test)
  end

  def self.prepare_context!(event, proof, explicit_test:)
    inbox, version, data, = eligible!(event, proof.reload, explicit_test: explicit_test, resolve_material: false)
    return unless data['material']['mode'] == 'context'

    begin
      Instagram::AmhContextRouter.prepare!(event, inbox, version)
      Instagram::AmhContextRouter.resolve(event, data['material'], version)
    rescue Unavailable
      Instagram::AmhDelivery.create_or_find_by!(inbound_event_id: event.id) do |record|
        record.proof = proof
        record.version_id = version['id']
        record.state = 'blocked'
        record.prompt_state = 'blocked'
        record.reason = 'context_unresolved'
      end
      raise
    end
  end

  def self.finish_like(delivery, explicit_test:)
    begin
      Instagram::AmhCommentLike.call(delivery: delivery, explicit_test: explicit_test)
    rescue StandardError => e
      Rails.logger.error("AMH comment like unavailable: #{e.class}")
    end
    Instagram::AmhPublicReply.call(delivery: delivery, explicit_test: explicit_test)
    delivery
  rescue StandardError => e
    # A like failure must never turn a persisted invitation into a failed send.
    Rails.logger.error("AMH comment like unavailable: #{e.class}")
    delivery
  end
  private_class_method :finish_like
end
