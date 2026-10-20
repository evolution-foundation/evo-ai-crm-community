# frozen_string_literal: true

# No mutation, contact lookup, network or send. Identity comes only from durable ingress.
class Instagram::AmhRegistrationBinding
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  HASH = /\A[0-9a-f]{64}\z/

  class << self
    def issue!(input)
      secret = ENV['INSTAGRAM_AMH_ASSOCIATION_SECRET'].to_s
      unavailable! unless valid_input?(input) && secret.bytesize >= 32
      link = Instagram::AmhShortLink.find(input['attribution_id'])
      link.with_lock do
        unavailable! unless matching_link?(link, input)
        payload = Instagram::AmhShortLink.encryptor.decrypt_and_verify(link.encrypted_payload)
        event = verified_event!(payload.fetch('event'), payload.fetch('graph'))
        encoded = Base64.urlsafe_encode64(JSON.generate(envelope(link, input, event)), padding: false)
        "#{encoded}.#{OpenSSL::HMAC.hexdigest('SHA256', secret, encoded)}"
      end
    end

    private

    def unavailable!
      raise Instagram::AmhShortLink::Unavailable
    end

    def valid_input?(input)
      %w[attribution_id request_id version_id].all? { |k| input[k].is_a?(String) && UUID.match?(input[k]) } &&
        %w[email_hash graph_digest].all? { |k| input[k].is_a?(String) && HASH.match?(input[k]) }
    end

    def matching_link?(link, input)
      link.usable? && link.material == input['material'] && link.version_id == input['version_id'] && link.graph_digest == input['graph_digest']
    end

    def envelope(link, input, event)
      { v: 1, mode: 'qa', request_id: input['request_id'], material: link.material, attribution_id: link.id,
        version_id: link.version_id, graph_digest: link.graph_digest, email_hash: input['email_hash'],
        expires_at: link.expires_at.to_i, event: event }
    end

    def verified_event!(source, graph)
      id = source['inbound_event_id']
      unavailable! unless id.is_a?(String) && UUID.match?(id)
      row = Instagram::AmhInboundEvent.find(id)
      event = row.contract
      unavailable! unless row.inbox_id == Instagram::AmhConnection.bound_inbox!.id && matching_event?(event, source)
      validate_graph_context!(event, graph)
      normalized_contract(event)
    end

    def validate_graph_context!(event, graph)
      data = graph.fetch('nodes').to_h { |node| [node['id'], node['data']] }
      unavailable! unless event['comment_text'].is_a?(String)
      # Evidence in the authenticated event is authoritative, even when the QA
      # issuance source omitted ad/media IDs. Never bypass the frozen scope.
      Instagram::AmhShortLink.validate_scope!(data.fetch('scope'), 'ad' => event['ad_id'], 'media' => event['media_id'])
      unavailable! unless Instagram::AmhVisualEngine.matches?(event['comment_text'], data.fetch('keyword'))
    rescue Instagram::AmhShortLink::Conflict
      unavailable!
    end

    def matching_event?(event, source)
      event['kind'] == 'comment' && event['event_id'] == source['comment'] &&
        matching_identity?(event.fetch('identity'), source) && matching_media?(event, source) &&
        %w[echo self spam].none? { |k| event[k] == true }
    end

    def matching_identity?(identity, source)
      identity['professional_account_id'] == source['account'] && identity['app_id'] == source['app'] &&
        identity['login_mode'] == 'instagram_login' && /\A[0-9]{1,64}\z/.match?(identity['igsid'].to_s) &&
        identity['igsid'] != identity['professional_account_id']
    end

    def matching_media?(event, source)
      (source['media'].blank? || source['media'] == event['media_id']) && (source['ad'].blank? || source['ad'] == event['ad_id'])
    end

    def normalized_contract(event)
      result = event.slice('identity', 'event_id', 'kind', 'occurred_at', 'username', 'display_name')
      result.delete('username') unless result['username'].nil? || /\A[A-Za-z0-9_.]{1,64}\z/.match?(result['username'].to_s)
      name = result['display_name']
      result.delete('display_name') if name.present? && (name.length > 255 || /[\x00-\x1f\x7f]/.match?(name))
      result
    end
  end
end
