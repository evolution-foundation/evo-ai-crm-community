# == Schema Information
#
# Table name: knowledge_documents
#
#  id                :uuid
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  knowledge_base_id :uuid             not null
#
# Indexes
#
#  index_knowledge_documents_on_knowledge_base_id_and_status  (knowledge_base_id,status)
#  index_knowledge_documents_on_tags                          (tags) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (knowledge_base_id => knowledge_bases.id)
#

class KnowledgeDocument < ApplicationRecord
  STATUSES = %w[processing active failed].freeze
  SOURCE_TYPES = %w[manual upload url].freeze

  belongs_to :knowledge_base
  has_many :knowledge_entries, dependent: :destroy
  has_one_attached :source_file

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  scope :for_knowledge_base, ->(id) { where(knowledge_base_id: id) }
  scope :ordered, -> { order(created_at: :desc) }
end
