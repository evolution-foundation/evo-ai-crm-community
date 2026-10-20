# frozen_string_literal: true

# Read-only projection. Never decrypt inbound contracts or issue links/messages.
class Instagram::AmhOperations
  LIMIT = 50

  def self.snapshot
    inbox = Instagram::AmhConnection.bound_inbox!
    events = Instagram::AmhInboundEvent.where(inbox_id: inbox.id)
    { at: Time.current.iso8601(6), outbound_enabled: false, state: 'paused',
      reception_enabled: ENV['INSTAGRAM_AMH_RECEPTION_ENABLED'] == 'true' && ENV['INSTAGRAM_AMH_INGRESS_ENABLED'] == 'true',
      inbound: { available: true, counts: events.group(:state).count,
                 recent: events.order(created_at: :desc, id: :desc).limit(LIMIT).as_json(only: %i[id state created_at updated_at]) },
      rules: rules, limit: LIMIT, activation: 'blocked_pending_controlled_validation',
      private_reply_button: 'pending_real_contract_validation',
      mautic: 'not_queried' }
  rescue Instagram::AmhConnection::ConfigurationError
    { at: Time.current.iso8601(6), outbound_enabled: false, state: 'paused', reception_enabled: false,
      inbound: { available: false, counts: {}, recent: [] }, rules: rules, limit: LIMIT,
      activation: 'blocked_pending_controlled_validation', private_reply_button: 'pending_real_contract_validation', mautic: 'not_queried' }
  end

  def self.rules
    Instagram::AmhVisualProof.order(updated_at: :desc, id: :desc).limit(LIMIT).map { |proof| rule(proof) }
  end

  def self.rule(proof)
    version = proof.versions.last
    graph = version ? version.fetch('graph') : proof.draft
    data = graph.fetch('nodes').to_h { |node| [node.fetch('id'), node.fetch('data')] }
    { id: proof.id, name: proof.name, state: 'paused', version: version&.fetch('number'),
      draft_changed: version.present? && proof.draft != graph,
      scope: data.fetch('scope').slice('account', 'ad', 'media'),
      material: data.fetch('material')['material'], keywords: data.fetch('keyword')['keywords'],
      preview: data.fetch('reply')['text'] }.merge(simulation_summary(proof))
  end

  def self.simulation_summary(proof)
    { simulations: proof.ledger.size, last_simulation: proof.ledger.last&.slice('outcome', 'at', 'outbound_calls') }
  end
end
