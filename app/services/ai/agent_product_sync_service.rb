# frozen_string_literal: true

# Syncs the product attachments of an AI Agent (stored in this CRM via
# `ai_agent_products`) into the agent's `config` JSONB managed by the
# evo_core service. The processor reads `agent.config["assigned_products"]`
# when building the system prompt — see
# `evo-ai-processor-community/src/services/adk/agents/llm_agent_builder.py`.
#
# Strategy:
#   - Re-read the full set of attached products from `ai_agent_products`
#   - Build a compact list (`to_prompt_summary`) capped at a sane size
#   - Merge into the current `agent.config` (preserving other keys like
#     `allow_pipeline_manipulation`, `allow_manage_labels`, …) via
#     EvoAiCoreService#update_agent (PUT /api/v1/agents/:id)
#
# Failure of the upstream sync MUST NOT block the CRM operation that
# triggered it (attach/detach). We log + re-raise only when the caller
# explicitly opts in with `raise_on_error: true`.
class Ai::AgentProductSyncService
  MAX_ASSIGNED_FOR_PROMPT = (ENV.fetch('AGENT_ASSIGNED_PRODUCTS_LIMIT', 50).to_i)

  def initialize(ai_agent_id:, request_headers: nil)
    @ai_agent_id = ai_agent_id
    @request_headers = request_headers
  end

  def call(raise_on_error: false)
    return false if @ai_agent_id.blank?

    products = Product
               .joins(:ai_agent_products)
               .where(ai_agent_products: { ai_agent_id: @ai_agent_id })
               .where(status: 'active')
               .limit(MAX_ASSIGNED_FOR_PROMPT)

    assigned_ids       = products.map { |p| p.id.to_s }
    assigned_summaries = products.map(&:to_prompt_summary)

    current_agent = fetch_current_agent
    return false unless current_agent

    current_config = current_agent['config'] || current_agent[:config] || {}
    current_config = {} unless current_config.is_a?(Hash)

    new_config = current_config.merge(
      'assigned_product_ids' => assigned_ids,
      'assigned_products'    => assigned_summaries
    )

    # The core service binds AgentUpdateRequest with `name` and `type` required,
    # so PUT /api/v1/agents/:id only accepts a full payload. Echo back the
    # current values for every required/binding field and only override `config`.
    payload = build_update_payload(current_agent, new_config)

    EvoAiCoreService.update_agent(@ai_agent_id, payload, @request_headers)
    true
  rescue StandardError => e
    Rails.logger.error(
      "[Ai::AgentProductSyncService] failed to sync products for agent=#{@ai_agent_id}: " \
      "#{e.class}: #{e.message}"
    )
    raise if raise_on_error

    false
  end

  private

  def fetch_current_agent
    agent = EvoAiCoreService.get_agent(@ai_agent_id, @request_headers)
    agent.is_a?(Hash) ? agent : nil
  rescue StandardError => e
    Rails.logger.error(
      "[Ai::AgentProductSyncService] failed to load agent #{@ai_agent_id}: #{e.class}: #{e.message}"
    )
    nil
  end

  # Mirror AgentBase (evo-ai-core-service) — only `name` and `type` are
  # `binding:"required"`, but echoing the full base avoids data loss when
  # the core rejects unknown / missing fields.
  def build_update_payload(agent, new_config)
    {
      name:         agent['name'] || agent[:name],
      description:  agent['description'] || agent[:description],
      type:         agent['type'] || agent[:type],
      model:        agent['model'] || agent[:model],
      api_key_id:   agent['api_key_id'] || agent[:api_key_id],
      instruction:  agent['instruction'] || agent[:instruction],
      card_url:     agent['card_url'] || agent[:card_url],
      folder_id:    agent['folder_id'] || agent[:folder_id],
      role:         agent['role'] || agent[:role],
      goal:         agent['goal'] || agent[:goal],
      config:       new_config
    }.compact
  end
end
