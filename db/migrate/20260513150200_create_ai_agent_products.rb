class CreateAiAgentProducts < ActiveRecord::Migration[7.1]
  def change
    # Join table connecting an AI Agent (lives in evo_core service, no FK
    # possible at the database level) to a Product in this CRM. The agent
    # association is validated via API in the application layer; only the
    # product side has a foreign key here.
    create_table :ai_agent_products, id: :uuid do |t|
      t.uuid :ai_agent_id, null: false
      t.references :product, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :ai_agent_products, [:ai_agent_id, :product_id], unique: true, name: 'index_ai_agent_products_unique'
    add_index :ai_agent_products, :ai_agent_id
  end
end
