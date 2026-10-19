# frozen_string_literal: true

# A separate inert namespace: never an AutomationRule, Journey or outbound job.
class Instagram::AmhVisualProof < ApplicationRecord
  self.table_name = 'instagram_amh_visual_proofs'
  validates :create_key, presence: true
  validates :name, presence: true, length: { maximum: 100 }

  def publish_version!(expected_lock, actor)
    with_lock do
      raise ActiveRecord::StaleObjectError.new(self, 'publish') unless lock_version == expected_lock

      Instagram::AmhVisualEngine.validate!(draft)
      raise Instagram::AmhVisualEngine::Invalid, 'Limite de 100 versões; crie outra prova' if versions.size >= 100

      version = { id: SecureRandom.uuid, number: versions.size + 1, graph: draft.deep_dup,
                  digest: Digest::SHA256.hexdigest(JSON.generate(draft)), at: Time.current.iso8601(6),
                  actor: actor, state: 'paused', mode: 'inert' }
      update!(versions: versions + [version])
    end
  end

  def simulate_version!(version_id, fixture, text)
    with_lock do
      version = versions.find { |v| v['id'] == version_id }
      raise Instagram::AmhVisualEngine::Invalid, 'Publique e selecione uma versão de simulação' unless version

      Instagram::AmhVisualEngine.validate_text!(text)
      text = Instagram::AmhVisualEngine.effective_text(version['graph'], fixture, text)
      key = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.key_generator.generate_key('amh-proof-dedup-v1'),
                                    JSON.generate([version['id'], fixture, text]))
      existing = ledger.find { |run| run['key'] == key }
      existing || append_run!(version, fixture, text, key)
    end
  end

  def append_run!(version, fixture, text, key)
    raise Instagram::AmhVisualEngine::Invalid, 'Limite de 800 recibos atingido' if ledger.size >= 800

    result = Instagram::AmhVisualEngine.simulate(version['graph'], fixture: fixture, text: text)
    run = result.merge(id: SecureRandom.uuid, key: key, version_id: version['id'], version_number: version['number'],
                       graph_digest: version['digest'], at: Time.current.iso8601(6))
    # Receipt writes hold the row lock but must not advance the draft revision.
    update_columns(ledger: ledger + [run], updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    run
  end

  def snapshot
    as_json(only: %i[id name draft versions ledger lock_version updated_at]).merge('outbound_enabled' => false, 'state' => 'paused')
  end
end
