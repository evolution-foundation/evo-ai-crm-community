class Api::V1::AiAgents::KnowledgeBasesController < Api::V1::BaseController
  # RULING (see ledger, Task 1.5): reuse the already-cataloged ai_agents.*
  # permission resource rather than inventing a new one — this controller was
  # missing require_permissions entirely in an earlier draft, which would have
  # let any authenticated user attach/detach a knowledge base on any agent.
  require_permissions({
    show: 'ai_agents.read',
    create: 'ai_agents.update',
    destroy: 'ai_agents.update'
  })

  def show
    attachment = AiAgentKnowledgeBase.find_by(ai_agent_id: params[:ai_agent_id])
    return head :not_found unless attachment

    render json: { knowledge_base_id: attachment.knowledge_base_id, knowledge_tags: attachment.knowledge_tags }
  end

  def create
    # Non-atomic before: destroy_all followed by a separate create! meant a
    # failure in create! (e.g. an invalid knowledge_base_id) left the agent's
    # previous attachment already gone with no re-sync, silently detaching it
    # while the caller only saw a validation error. Wrap both in a
    # transaction so a failed create! rolls back the destroy_all too.
    attachment = ActiveRecord::Base.transaction do
      AiAgentKnowledgeBase.where(ai_agent_id: params[:ai_agent_id]).destroy_all
      AiAgentKnowledgeBase.create!(
        ai_agent_id: params[:ai_agent_id],
        knowledge_base_id: params[:knowledge_base_id],
        knowledge_tags: Array(params[:knowledge_tags])
      )
    end
    Ai::AgentKnowledgeBaseSyncService.new(ai_agent_id: params[:ai_agent_id], request_headers: request.headers).call
    render json: { knowledge_base_id: attachment.knowledge_base_id, knowledge_tags: attachment.knowledge_tags }, status: :created
  end

  def destroy
    AiAgentKnowledgeBase.where(ai_agent_id: params[:ai_agent_id]).destroy_all
    Ai::AgentKnowledgeBaseSyncService.new(ai_agent_id: params[:ai_agent_id], request_headers: request.headers).call
    head :no_content
  end
end
