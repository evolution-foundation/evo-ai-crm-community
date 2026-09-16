class CreateKnowledgeBases < ActiveRecord::Migration[7.0]
  def change
    create_table :knowledge_bases, id: :uuid do |t|
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.boolean :default, null: false, default: false
      t.string :embedding_model, null: false, default: 'text-embedding-3-small'
      t.timestamps
    end

    add_index :knowledge_bases, [:default]
  end
end
