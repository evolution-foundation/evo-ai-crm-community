class AddCascadeToAiAgentKnowledgeBasesFk < ActiveRecord::Migration[7.1]
  def change
    # The original migration (20260915090400) added a plain FK with no
    # on_delete, so destroying an attached KnowledgeBase raises
    # ActiveRecord::InvalidForeignKey instead of cascading. Match the sibling
    # ai_agent_products -> products FK pattern (on_delete: :cascade).
    remove_foreign_key :ai_agent_knowledge_bases, :knowledge_bases
    add_foreign_key :ai_agent_knowledge_bases, :knowledge_bases, on_delete: :cascade
  end
end
