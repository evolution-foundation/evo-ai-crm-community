# == Schema Information
#
# Table name: knowledge_entries
#
#  id                    :uuid
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  knowledge_document_id :uuid             not null
#  knowledge_base_id     :uuid             not null
#
# Indexes
#
#  index_knowledge_entries_on_embedding       (embedding) USING ivfflat
#  index_knowledge_entries_on_tags            (tags) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (knowledge_base_id => knowledge_bases.id)
#  fk_rails_...  (knowledge_document_id => knowledge_documents.id)
#

class KnowledgeEntry < ApplicationRecord
  belongs_to :knowledge_document
  belongs_to :knowledge_base

  has_neighbors :embedding, normalize: true

  validates :content, presence: true

  before_validation :ensure_denormalized_knowledge_base_id

  scope :for_knowledge_base, ->(id) { where(knowledge_base_id: id) }
  scope :with_any_tag, ->(tags) { where('tags ?| array[:tags]', tags: Array(tags)) }

  # query_embedding: Array<Float> (1536 dims), already produced by
  # Knowledge::EmbeddingService — this method does NOT call the embeddings
  # API itself, so it stays fast and unit-testable without network stubs.
  def self.search(knowledge_base_id:, query_embedding:, tags: nil, limit: 5)
    scope = for_knowledge_base(knowledge_base_id)
    scope = scope.with_any_tag(tags) if tags.present?
    scope.nearest_neighbors(:embedding, query_embedding, distance: 'cosine').limit(limit)
  end

  private

  def ensure_denormalized_knowledge_base_id
    self.knowledge_base_id ||= knowledge_document&.knowledge_base_id
  end
end
