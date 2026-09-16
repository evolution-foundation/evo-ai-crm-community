# frozen_string_literal: true

module KnowledgeBaseSerializer
  extend self

  def serialize(knowledge_base)
    return nil unless knowledge_base

    {
      id: knowledge_base.id,
      name: knowledge_base.name,
      active: knowledge_base.active,
      default: knowledge_base.default,
      embedding_model: knowledge_base.embedding_model
    }
  end

  def serialize_collection(knowledge_bases)
    return [] unless knowledge_bases

    knowledge_bases.map { |knowledge_base| serialize(knowledge_base) }
  end
end
