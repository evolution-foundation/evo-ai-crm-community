class Api::V1::Internal::KnowledgeController < Api::ServiceController
  def search
    knowledge_base_id = params[:knowledge_base_id]
    query = params[:query].to_s
    tags = params[:tags]
    limit = (params[:max_results] || 5).to_i

    return render json: { error: 'knowledge_base_id is required' }, status: :bad_request if knowledge_base_id.blank?
    return render json: { results: [] } if query.blank?

    embedding = Knowledge::EmbeddingService.new.embed(query)
    entries = KnowledgeEntry.search(knowledge_base_id: knowledge_base_id, query_embedding: embedding, tags: tags, limit: limit)

    render json: {
      results: entries.map do |entry|
        {
          content: entry.content,
          tags: entry.tags,
          document_id: entry.knowledge_document_id,
          document_title: entry.knowledge_document.title
        }
      end,
      total: entries.size
    }
  rescue Knowledge::EmbeddingService::Error => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
