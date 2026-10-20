# frozen_string_literal: true

class Instagram::AmhShortLink < ApplicationRecord
  self.table_name = 'instagram_amh_short_links'
  CODE = /\A[A-Za-z0-9_-]{8}\z/
  DESTINATIONS = { 'amh' => '/lp/amh-na-pratica-ginecologica', 'amh-consultorio' => '/lp/amh-no-consultorio' }.freeze
  class Unavailable < StandardError; end
  class Conflict < StandardError; end

  def self.encryptor
    ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key('amh-short-links-v1', 32),
                                        cipher: 'aes-256-gcm', serializer: JSON)
  end

  # Explicit QA issuance only. No webhook, scheduler or transport invokes this method.
  def self.issue_qa!(proof:, version_id:, event:)
    Instagram::AmhVisualProof.with_mapping_lock do
      proof.reload
      issue_snapshot!(proof, version_id, event)
    end
  end

  def self.issue_snapshot!(proof, version_id, event)
    version = proof.versions.find { |v| v['id'] == version_id }
    raise Unavailable unless version

    graph = Instagram::AmhVisualEngine.validate!(version.fetch('graph'))
    data = graph['nodes'].to_h { |node| [node['id'], node['data']] }
    validate_event!(event, data)
    material = data['material'].fetch('material')
    key = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('amh-link-event-v1'),
                                  JSON.generate(event.values_at('account', 'app', 'comment')))
    existing = find_by(event_hash: key)
    return existing.recover_qa!(version['id']) if existing

    ensure_unambiguous!(proof, event)
    issue_unique!(key, version, material, event)
  end

  def self.ensure_unambiguous!(proof, event)
    # QA mappings are frozen proof versions. Do not silently pick one of several eligible mappings.
    Instagram::AmhVisualProof.where.not(id: proof.id).find_each do |other|
      raise Conflict if other.versions.any? { |version| conflicting_version?(version, event) }
    end
  end

  def self.conflicting_version?(version, event)
    data = version.fetch('graph').fetch('nodes').to_h { |n| [n['id'], n['data']] }
    return false unless candidate_scope?(data.fetch('scope'), event)

    # Shared media without ad evidence is ambiguous even when keywords differ.
    event['ad'].blank? || Instagram::AmhVisualEngine.matches?(event['text'], data.fetch('keyword'))
  end

  def self.candidate_scope?(scope, event)
    return false unless scope['account'] == event['account']
    return scope['ad'] == event['ad'] if event['ad'].present?

    scope['media'].present? && scope['media'] == event['media']
  end

  def self.validate_event!(event, data)
    validate_event_shape!(event)
    scope = data.fetch('scope')
    raise Unavailable unless event['account'] == scope['account']

    validate_scope!(scope, event)
    raise Unavailable unless Instagram::AmhVisualEngine.matches?(event['text'], data.fetch('keyword'))
  end

  def self.validate_event_shape!(event)
    raise Unavailable unless event.is_a?(Hash)
    raise Unavailable unless (event.keys - %w[account app comment text ad media inbound_event_id]).empty?
    raise Unavailable unless %w[account app comment].all? { |k| Instagram::AmhVisualEngine.valid_string?(event[k], 200) }
    raise Unavailable unless Instagram::AmhVisualEngine.valid_string?(event['text'], 2200)

    validate_optional_event_ids!(event)
  end

  def self.validate_optional_event_ids!(event)
    raise Unavailable unless %w[ad media].all? { |k| optional_id?(event[k]) }
    raise Unavailable unless valid_inbound_reference?(event['inbound_event_id'])
  end

  def self.valid_inbound_reference?(id)
    id.nil? || (id.is_a?(String) && Instagram::AmhRegistrationBinding::UUID.match?(id))
  end

  def self.optional_id?(value)
    value.nil? || Instagram::AmhVisualEngine.valid_string?(value, 100)
  end

  def self.validate_scope!(scope, event)
    # A present ad ID is authoritative. Never fall back from a different ad to the same media.
    if event['ad'].present?
      raise Unavailable unless event['ad'] == scope['ad']

      validate_media_consistency!(scope, event)
    else
      raise Unavailable unless scope['media'].present? && event['media'] == scope['media']
    end
  end

  def self.validate_media_consistency!(scope, event)
    return unless event['media'].present? && scope['media'].present?

    raise Conflict unless event['media'] == scope['media']
  end

  def self.issue_unique!(key, version, material, event)
    8.times do
      existing = find_by(event_hash: key)
      return existing.recover_qa!(version['id']) if existing

      code = SecureRandom.urlsafe_base64(6, false)
      payload = { 'code' => code, 'event' => event.except('text'), 'mode' => 'qa', 'graph' => version['graph'] }
      begin
        # Savepoint keeps a unique-index collision from aborting the caller's transaction.
        row = transaction(requires_new: true) do
          create!(event_hash: key, code_hash: Digest::SHA256.hexdigest(code), material: material,
                  version_id: version['id'], graph_digest: version['digest'], expires_at: 30.days.from_now,
                  encrypted_payload: encryptor.encrypt_and_sign(payload))
        end
        return row.recover_qa!(version['id'])
      rescue ActiveRecord::RecordNotUnique
        next # Concurrent same event or random code collision: re-read before generating again.
      end
    end
    raise Unavailable
  end

  def self.resolve(code)
    raise Unavailable unless code.is_a?(String) && CODE.match?(code)

    row = find_by(code_hash: Digest::SHA256.hexdigest(code))
    raise Unavailable unless row

    row.with_lock { row.resolution }
  end

  def resolution
    raise Unavailable unless usable?

    { attribution_id: id, material: material, destination: DESTINATIONS.fetch(material),
      version_id: version_id, graph_digest: graph_digest, expires_at: expires_at.to_i, mode: 'qa' }
  end

  def usable?
    revoked_at.nil? && expires_at > Time.current && encrypted_payload.present?
  end

  def recover_qa!(version)
    with_lock { recover_locked_qa!(version) }
  end

  def recover_locked_qa!(version)
    raise Conflict unless version_id == version
    raise Unavailable unless usable?

    code = self.class.encryptor.decrypt_and_verify(encrypted_payload).fetch('code')
    { id: id, url: "https://co.agenciavetorial.com/#{code}", material: material, expires_at: expires_at,
      mode: 'qa', outbound_enabled: false }
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    # Never rotate/reissue an existing event silently when the decryption key is unavailable.
    raise Conflict
  end

  def revoke!
    with_lock { update!(revoked_at: Time.current, encrypted_payload: nil) }
  end

  # Keep hashes permanently so expired/revoked codes and event keys cannot be reissued.
  def self.compact_expired!
    where('expires_at <= ?', Time.current).where.not(encrypted_payload: nil).update_all(encrypted_payload: nil) # rubocop:disable Rails/SkipsModelValidations
  end
end
