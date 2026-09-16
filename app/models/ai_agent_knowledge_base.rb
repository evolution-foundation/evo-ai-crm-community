class AiAgentKnowledgeBase < ApplicationRecord
  belongs_to :knowledge_base

  validates :ai_agent_id, presence: true
  validates :ai_agent_id, uniqueness: { scope: :knowledge_base_id }
end
