# frozen_string_literal: true

module KnowledgeDocumentSerializer
  extend self

  def serialize(document)
    return nil unless document

    {
      id: document.id,
      title: document.title,
      description: document.description,
      status: document.status,
      source_type: document.source_type,
      tags: document.tags,
      created_at: document.created_at&.iso8601
    }
  end

  def serialize_collection(documents)
    return [] unless documents

    documents.map { |document| serialize(document) }
  end
end
