class Api::V1::KnowledgeBasesController < Api::V1::BaseController
  include KnowledgeSearchParams

  require_permissions({
    index: 'ai_agents.read',
    create: 'ai_agents.create',
    destroy: 'ai_agents.delete',
    search: 'ai_agents.read'
  })

  before_action :knowledge_base, only: [:destroy, :search]

  def index
    @knowledge_bases = KnowledgeBase.order(created_at: :desc)
    success_response(data: KnowledgeBaseSerializer.serialize_collection(@knowledge_bases))
  end

  def create
    @knowledge_base = KnowledgeBase.new(knowledge_base_params)
    if @knowledge_base.save
      success_response(data: KnowledgeBaseSerializer.serialize(@knowledge_base), status: :created)
    else
      render json: { errors: @knowledge_base.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @knowledge_base.destroy
    head :no_content
  end

  def search
    query = params[:query].to_s
    return render json: { results: [] } if query.blank?

    embedding = Knowledge::EmbeddingService.new.embed(query)
    entries = KnowledgeEntry.search(
      knowledge_base_id: @knowledge_base.id,
      query_embedding: embedding,
      tags: params[:tags],
      limit: clamped_max_results(default: 10)
    )

    render json: { results: entries.map { |e| { content: e.content, tags: e.tags, document_title: e.knowledge_document.title } } }
  rescue Knowledge::EmbeddingService::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def knowledge_base
    @knowledge_base = KnowledgeBase.find(params[:id])
  end

  def knowledge_base_params
    # embedding_model is intentionally not permitted here: the column exists
    # and defaults to the fixed value Knowledge::EmbeddingService hardcodes
    # (text-embedding-3-small, vector(1536)), but the API does not honor a
    # caller-supplied model/dimension, so exposing it as writable would
    # silently ignore whatever the caller sets.
    params.require(:knowledge_base).permit(:name, :active, :default)
  end
end
