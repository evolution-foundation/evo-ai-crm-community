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
    # HNSW (not ivfflat) is chosen deliberately: ivfflat trains its list
    # centroids from the rows present at index-build time, so building it on
    # this table (empty on a fresh deploy) produces a degenerate index with
    # no real clustering once data is inserted later — it does NOT gracefully
    # fall back to a sequential scan. HNSW needs no representative data at
    # build time, so it stays correct regardless of when rows are added.
    add_index :knowledge_entries, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
