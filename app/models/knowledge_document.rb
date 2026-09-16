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
  STATUSES = %w[crawling processing active failed].freeze
  SOURCE_TYPES = %w[manual upload url].freeze
  MAX_FILE_SIZE = 50.megabytes
  SUPPORTED_UPLOAD_TYPES = %w[
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    text/html
    text/plain
    text/markdown
  ].freeze

  belongs_to :knowledge_base
  has_many :knowledge_entries, dependent: :destroy
  has_one_attached :source_file

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validate :validate_file_size, if: -> { source_file.attached? }
  validate :validate_file_type, if: -> { source_file.attached? }

  after_create_commit :enqueue_ingestion

  scope :for_knowledge_base, ->(id) { where(knowledge_base_id: id) }
  scope :ordered, -> { order(created_at: :desc) }

  private

  def enqueue_ingestion
    return unless status == 'processing'

    Knowledge::IngestJob.perform_later(self)
  end

  def validate_file_size
    # NOTE: For the upload action, this validation is intercepted earlier by
    # Api::V1::KnowledgeDocumentsController#extract_uploaded_text, which checks
    # file size before TextExtractor processing. This validation still applies to
    # other paths that attach source_file without going through extract_uploaded_text.
    return unless source_file.blob.byte_size > MAX_FILE_SIZE

    errors.add(:source_file, "must be smaller than #{MAX_FILE_SIZE / 1.megabyte}MB")
  end

  def validate_file_type
    return if SUPPORTED_UPLOAD_TYPES.include?(source_file.blob.content_type)

    errors.add(:source_file, "unsupported file type: #{source_file.blob.content_type}")
  end
end
