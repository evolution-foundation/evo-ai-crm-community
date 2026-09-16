class CreateKnowledgeDocuments < ActiveRecord::Migration[7.0]
  def change
    create_table :knowledge_documents, id: :uuid do |t|
      t.references :knowledge_base, type: :uuid, null: false, foreign_key: true
      t.string :title, null: false
      t.text :description
      t.string :source_type, null: false, default: 'manual' # manual | upload | url
      t.string :source_url
      t.string :status, null: false, default: 'processing' # processing | active | failed
      t.string :last_error
      t.jsonb :tags, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :knowledge_documents, :tags, using: :gin
    add_index :knowledge_documents, [:knowledge_base_id, :status]
  end
end
