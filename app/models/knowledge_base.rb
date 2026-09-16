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
  has_many :ai_agent_knowledge_bases, dependent: :destroy

  validates :name, presence: true

  before_save :ensure_single_default

  # The join rows are cascade-deleted at the DB level (see migration
  # 20260916090000), but nothing else would re-sync the affected agents'
  # evo_core config afterward, leaving `load_knowledge: true` and a
  # `knowledge_base_id` pointing at a deleted row. Capture the affected
  # agent ids *before* destroy and re-sync each one afterward so their
  # config is updated to `load_knowledge: false`.
  #
  # prepend: true is required: `has_many ..., dependent: :destroy` above
  # registers its own before_destroy callback at class-body time, which
  # would otherwise run first and delete the join rows before this callback
  # gets a chance to read them, leaving @attached_ai_agent_ids empty.
  before_destroy :capture_attached_ai_agent_ids, prepend: true
  after_destroy :sync_detached_ai_agents

  private

  def ensure_single_default
    return unless default? && default_changed?

    self.class.where.not(id: id).update_all(default: false)
  end

  def capture_attached_ai_agent_ids
    @attached_ai_agent_ids = ai_agent_knowledge_bases.pluck(:ai_agent_id)
  end

  def sync_detached_ai_agents
    Array(@attached_ai_agent_ids).each do |ai_agent_id|
      Ai::AgentKnowledgeBaseSyncService.new(ai_agent_id: ai_agent_id).call
    end
  end
end
