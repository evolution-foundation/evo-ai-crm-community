class CreateKnowledgeEntries < ActiveRecord::Migration[7.0]
  def change
    enable_extension 'vector' unless extension_enabled?('vector')

    create_table :knowledge_entries, id: :uuid do |t|
      t.references :knowledge_document, type: :uuid, null: false, foreign_key: true
      t.references :knowledge_base, type: :uuid, null: false, foreign_key: true
      t.integer :chunk_index, null: false, default: 0
      t.text :content, null: false
      t.jsonb :tags, null: false, default: []
      t.vector :embedding, limit: 1536
      t.timestamps
    end

    add_index :knowledge_entries, :tags, using: :gin
    # ivfflat requires an approximate row-count estimate at creation time;
    # for a fresh table this is fine — Postgres will use a sequential scan
    # until enough rows exist, then the planner picks the index up.
    add_index :knowledge_entries, :embedding, using: :ivfflat, opclass: :vector_cosine_ops
  end
end
