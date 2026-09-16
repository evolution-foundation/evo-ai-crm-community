class CreateAiAgentKnowledgeBases < ActiveRecord::Migration[7.0]
  def change
    create_table :ai_agent_knowledge_bases, id: :uuid, if_not_exists: true do |t|
      t.uuid :ai_agent_id, null: false
      t.references :knowledge_base, type: :uuid, null: false, foreign_key: true
      t.jsonb :knowledge_tags, null: false, default: []
      t.timestamps
    end

    add_index :ai_agent_knowledge_bases, [:ai_agent_id, :knowledge_base_id], unique: true, name: 'index_ai_agent_knowledge_bases_unique', if_not_exists: true
    add_index :ai_agent_knowledge_bases, :ai_agent_id, if_not_exists: true
  end
end
