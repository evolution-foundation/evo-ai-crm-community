# frozen_string_literal: true

# Read-only projection. Never decrypt inbound contracts or issue links/messages.
class Instagram::AmhOperations
  LIMIT = 50

  def self.snapshot
    inbox = Instagram::AmhConnection.bound_inbox!
    { at: Time.current.iso8601(6), outbound_enabled: Instagram::AmhExecutor.enabled? && Instagram::AmhVisualProof.where(audience: %w[test active]).exists?,
      state: Instagram::AmhExecutor.enabled? ? 'configured' : 'paused',
      reception_enabled: ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] == 'true' && ENV['INSTAGRAM_AMH_INGRESS_ENABLED'] == 'true',
      inbound: inbound(inbox),
      rules: rules, limit: LIMIT, activation: Instagram::AmhExecutor.enabled? ? 'controlled_test_required_per_version' : 'execution_disabled',
      private_reply_button: 'pending_real_contract_validation',
      mautic: 'not_queried' }
  rescue Instagram::AmhConnection::ConfigurationError
    { at: Time.current.iso8601(6), outbound_enabled: false, state: 'paused', reception_enabled: false,
      inbound: { available: false, counts_scope: 'recent_receipts', counts: {}, recent: [] }, rules: rules, limit: LIMIT,
      activation: Instagram::AmhExecutor.enabled? ? 'controlled_test_required_per_version' : 'execution_disabled', private_reply_button: 'pending_real_contract_validation', mautic: 'not_queried' }
  end

  def self.inbound(inbox)
    recent = Instagram::AmhInboundEvent.where(inbox_id: inbox.id).order(created_at: :desc, id: :desc).limit(LIMIT)
                                       .select(:id, :state, :created_at, :updated_at).as_json(only: %i[id state created_at updated_at])
    { available: true, counts_scope: 'recent_receipts', counts: recent.map { |row| row.fetch('state') }.tally, recent: recent }
  end

  def self.rules
    Instagram::AmhVisualProof.select(Arel.sql(<<~SQL.squish)).order(updated_at: :desc, id: :desc).limit(LIMIT).map { |proof| rule(proof) }
      id, name, draft, audience,
      COALESCE((SELECT v FROM jsonb_array_elements(versions) v WHERE v->>'id' = active_version_id LIMIT 1), versions -> -1) AS operation_version,
      jsonb_array_length(ledger) AS operation_simulations,
      ledger -> -1 AS operation_last_simulation
    SQL
  end

  def self.rule(proof)
    version = proof['operation_version']
    graph = version ? version.fetch('graph') : proof.draft
    data = graph.fetch('nodes').to_h { |node| [node.fetch('id'), node.fetch('data')] }
    { id: proof.id, name: proof.name, state: proof.audience, version: version&.fetch('number'),
      draft_changed: version.present? && proof.draft != graph,
      scope: data.fetch('scope').slice('account', 'ad', 'media'),
      material: data.fetch('material')['material'], keywords: data.fetch('keyword')['keywords'],
      preview: data.fetch('reply')['text'] }.merge(simulation_summary(proof))
  end

  def self.simulation_summary(proof)
    { simulations: proof['operation_simulations'],
      last_simulation: proof['operation_last_simulation']&.slice('outcome', 'at', 'outbound_calls') }
  end
end
