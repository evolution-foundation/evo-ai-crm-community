# frozen_string_literal: true

# Syncs the knowledge base attachment of an AI Agent (stored in this CRM via
# `ai_agent_knowledge_bases`) into the agent's `config` JSONB managed by the
# evo_core service. The processor reads `agent.config["knowledge_base_id"]`/
# `agent.config["knowledge_tags"]` when deciding whether/how to ground
# responses in the knowledge base (Task 4.2).
#
# Strategy:
#   - Re-read the current attachment (at most one per agent) from
#     `ai_agent_knowledge_bases`
#   - Merge `load_knowledge`, `knowledge_base_id`, `knowledge_tags` into the
#     current `agent.config` (preserving other keys) via
#     EvoAiCoreService#update_agent (PUT /api/v1/agents/:id)
#
# Failure of the upstream sync MUST NOT block the CRM operation that
# triggered it (attach/detach). We log + re-raise only when the caller
# explicitly opts in with `raise_on_error: true`. Mirrors
# `Ai::AgentProductSyncService`.
class Ai::AgentKnowledgeBaseSyncService
  def initialize(ai_agent_id:, request_headers: nil)
    @ai_agent_id = ai_agent_id
    @request_headers = request_headers
  end

  def call(raise_on_error: false)
    return false if @ai_agent_id.blank?

    attachment = AiAgentKnowledgeBase.find_by(ai_agent_id: @ai_agent_id)
    current_agent = fetch_current_agent
    return false unless current_agent

    current_config = current_agent['config'] || current_agent[:config] || {}
    current_config = {} unless current_config.is_a?(Hash)

    new_config = current_config.merge(
      'load_knowledge' => attachment.present?,
      'knowledge_base_id' => attachment&.knowledge_base_id,
      'knowledge_tags' => attachment&.knowledge_tags || []
    )

    payload = build_update_payload(current_agent, new_config)
    EvoAiCoreService.update_agent(@ai_agent_id, payload, @request_headers)
    true
  rescue StandardError => e
    Rails.logger.error(
      "[Ai::AgentKnowledgeBaseSyncService] failed to sync knowledge base for agent=#{@ai_agent_id}: #{e.class}: #{e.message}"
    )
    raise if raise_on_error

    false
  end

  private

  def fetch_current_agent
    agent = EvoAiCoreService.get_agent(@ai_agent_id, @request_headers)
    agent.is_a?(Hash) ? agent : nil
  rescue StandardError => e
    Rails.logger.error("[Ai::AgentKnowledgeBaseSyncService] failed to load agent #{@ai_agent_id}: #{e.class}: #{e.message}")
    nil
  end

  def build_update_payload(agent, new_config)
    {
      name: agent['name'] || agent[:name],
      description: agent['description'] || agent[:description],
      type: agent['type'] || agent[:type],
      model: agent['model'] || agent[:model],
      api_key_id: agent['api_key_id'] || agent[:api_key_id],
      instruction: agent['instruction'] || agent[:instruction],
      card_url: agent['card_url'] || agent[:card_url],
      folder_id: agent['folder_id'] || agent[:folder_id],
      role: agent['role'] || agent[:role],
      goal: agent['goal'] || agent[:goal],
      config: new_config
    }.compact
  end
end
