# == Schema Information
#
# Table name: knowledge_bases
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(TRUE), not null
#  default         :boolean          default(FALSE), not null
#  embedding_model :string           default("text-embedding-3-small"), not null
#  name            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class KnowledgeBase < ApplicationRecord
  has_many :knowledge_documents, dependent: :destroy

  validates :name, presence: true

  before_save :ensure_single_default

  private

  def ensure_single_default
    return unless default? && default_changed?

    self.class.where.not(id: id).update_all(default: false)
  end
end
