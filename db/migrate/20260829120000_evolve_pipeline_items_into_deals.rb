class EvolvePipelineItemsIntoDeals < ActiveRecord::Migration[7.1]
  DEFAULT_DEAL_ATTRIBUTES = %w[utm_source utm_medium utm_campaign utm_content utm_term].freeze

  def up
    add_deal_columns
    create_deal_associations
    create_deal_history
    migrate_scheduled_action_deal_id
    backfill_deals
    add_default_deal_attributes
  end

  def down
    restore_scheduled_action_legacy_deal_id
    drop_table :deal_history_events, if_exists: true
    drop_table :deal_conversations, if_exists: true
    drop_table :deal_contacts, if_exists: true
    remove_reference :pipeline_items, :primary_contact, type: :uuid, foreign_key: { to_table: :contacts } if column_exists?(:pipeline_items, :primary_contact_id)
    remove_reference :pipeline_items, :company, type: :uuid, foreign_key: { to_table: :contacts } if column_exists?(:pipeline_items, :company_id)
    remove_reference :pipeline_items, :owner, type: :uuid, foreign_key: { to_table: :users } if column_exists?(:pipeline_items, :owner_id)
    remove_column :pipeline_items, :notes if column_exists?(:pipeline_items, :notes)
    remove_column :pipeline_items, :currency if column_exists?(:pipeline_items, :currency)
    remove_column :pipeline_items, :value if column_exists?(:pipeline_items, :value)
    remove_column :pipeline_items, :title if column_exists?(:pipeline_items, :title)
  end

  private

  def add_deal_columns
    remove_index :pipeline_items, name: 'idx_pipeline_items_active_contact_per_pipeline', if_exists: true
    remove_index :pipeline_items, name: 'idx_pipeline_items_active_conversation_per_pipeline', if_exists: true
    add_index :pipeline_items, [:contact_id, :pipeline_id], name: 'index_pipeline_items_on_contact_and_pipeline', if_not_exists: true
    add_index :pipeline_items, [:conversation_id, :pipeline_id], name: 'index_pipeline_items_on_conversation_and_pipeline', if_not_exists: true
    add_column :pipeline_items, :title, :string unless column_exists?(:pipeline_items, :title)
    add_column :pipeline_items, :value, :decimal, precision: 14, scale: 2, default: 0, null: false unless column_exists?(:pipeline_items, :value)
    add_column :pipeline_items, :currency, :string, limit: 3, default: 'BRL', null: false unless column_exists?(:pipeline_items, :currency)
    add_column :pipeline_items, :notes, :text unless column_exists?(:pipeline_items, :notes)
    add_reference :pipeline_items, :owner, type: :uuid, foreign_key: { to_table: :users }, index: true unless column_exists?(:pipeline_items, :owner_id)
    add_reference :pipeline_items, :company, type: :uuid, foreign_key: { to_table: :contacts }, index: true unless column_exists?(:pipeline_items, :company_id)
    add_reference :pipeline_items, :primary_contact, type: :uuid, foreign_key: { to_table: :contacts }, index: true unless column_exists?(:pipeline_items, :primary_contact_id)
  end

  def create_deal_associations
    create_table :deal_contacts, id: :uuid, if_not_exists: true do |t|
      t.references :pipeline_item, type: :uuid, null: false, foreign_key: true, index: false
      t.references :contact, type: :uuid, null: false, foreign_key: true, index: true
      t.timestamps
      t.index [:pipeline_item_id, :contact_id], unique: true
    end

    create_table :deal_conversations, id: :uuid, if_not_exists: true do |t|
      t.references :pipeline_item, type: :uuid, null: false, foreign_key: true, index: false
      t.references :conversation, type: :uuid, null: false, foreign_key: true, index: true
      t.timestamps
      t.index [:pipeline_item_id, :conversation_id], unique: true, name: 'index_deal_conversations_unique'
    end
  end

  def create_deal_history
    create_table :deal_history_events, id: :uuid, if_not_exists: true do |t|
      # Audit records intentionally keep the deal UUID without a foreign key.
      # This allows the immutable timeline to survive a hard-deleted deal.
      t.references :pipeline_item, type: :uuid, null: false, index: true
      t.references :actor, type: :uuid, foreign_key: { to_table: :users }, index: true
      t.string :action, null: false
      t.string :source, null: false, default: 'system'
      # `changes` is an Active Record instance method and cannot safely be used
      # as a model attribute. Keep the public API key as `changes`, but persist
      # the append-only payload under an unambiguous column name.
      t.jsonb :change_set, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.index [:pipeline_item_id, :created_at], name: 'index_deal_history_on_deal_and_created_at'
    end
  end

  def migrate_scheduled_action_deal_id
    return unless table_exists?(:scheduled_actions)

    # Preserve the former bigint identifier under an explicit compatibility
    # name and make deal_id the canonical UUID foreign key.
    if scheduled_action_deal_id_type == :integer
      remove_index :scheduled_actions, name: 'idx_scheduled_actions_deal_status', if_exists: true
      remove_index :scheduled_actions, :deal_id, if_exists: true
      if column_exists?(:scheduled_actions, :legacy_deal_id)
        execute 'UPDATE scheduled_actions SET legacy_deal_id = deal_id WHERE legacy_deal_id IS NULL AND deal_id IS NOT NULL'
        remove_column :scheduled_actions, :deal_id
      else
        rename_column :scheduled_actions, :deal_id, :legacy_deal_id
      end
    end

    add_index :scheduled_actions, :legacy_deal_id, if_not_exists: true
    add_column :scheduled_actions, :deal_id, :uuid unless column_exists?(:scheduled_actions, :deal_id)
    migrate_draft_deal_uuid
    add_index :scheduled_actions, :deal_id, if_not_exists: true
    add_index :scheduled_actions, [:deal_id, :status], name: 'idx_scheduled_actions_deal_status', if_not_exists: true
    unless foreign_key_exists?(:scheduled_actions, :pipeline_items, column: :deal_id)
      add_foreign_key :scheduled_actions, :pipeline_items, column: :deal_id
    end
  end

  def restore_scheduled_action_legacy_deal_id
    return unless table_exists?(:scheduled_actions)

    remove_foreign_key :scheduled_actions, column: :deal_uuid if foreign_key_exists?(:scheduled_actions, column: :deal_uuid)
    remove_column :scheduled_actions, :deal_uuid if column_exists?(:scheduled_actions, :deal_uuid)
    remove_foreign_key :scheduled_actions, column: :deal_id if foreign_key_exists?(:scheduled_actions, column: :deal_id)

    if scheduled_action_deal_id_type == :uuid
      remove_index :scheduled_actions, name: 'idx_scheduled_actions_deal_status', if_exists: true
      remove_index :scheduled_actions, :deal_id, if_exists: true
      remove_column :scheduled_actions, :deal_id
    end

    return unless column_exists?(:scheduled_actions, :legacy_deal_id)

    if column_exists?(:scheduled_actions, :deal_id)
      remove_column :scheduled_actions, :legacy_deal_id
    else
      remove_index :scheduled_actions, :legacy_deal_id, if_exists: true
      rename_column :scheduled_actions, :legacy_deal_id, :deal_id
      add_index :scheduled_actions, :deal_id, if_not_exists: true
      add_index :scheduled_actions, [:deal_id, :status], name: 'idx_scheduled_actions_deal_status', if_not_exists: true
    end
  end

  def scheduled_action_deal_id_type
    connection.columns(:scheduled_actions).find { |column| column.name == 'deal_id' }&.type
  end

  def migrate_draft_deal_uuid
    return unless column_exists?(:scheduled_actions, :deal_uuid)

    execute 'UPDATE scheduled_actions SET deal_id = deal_uuid WHERE deal_id IS NULL AND deal_uuid IS NOT NULL'
    remove_foreign_key :scheduled_actions, column: :deal_uuid if foreign_key_exists?(:scheduled_actions, column: :deal_uuid)
    remove_index :scheduled_actions, :deal_uuid, if_exists: true
    remove_column :scheduled_actions, :deal_uuid
  end

  def backfill_deals
    execute <<~SQL.squish
      INSERT INTO deal_conversations (id, pipeline_item_id, conversation_id, created_at, updated_at)
      SELECT gen_random_uuid(), id, conversation_id, created_at, updated_at
      FROM pipeline_items WHERE conversation_id IS NOT NULL
      ON CONFLICT (pipeline_item_id, conversation_id) DO NOTHING
    SQL
    execute <<~SQL.squish
      INSERT INTO deal_contacts (id, pipeline_item_id, contact_id, created_at, updated_at)
      SELECT gen_random_uuid(), pi.id, COALESCE(pi.contact_id, c.contact_id), pi.created_at, pi.updated_at
      FROM pipeline_items pi LEFT JOIN conversations c ON c.id = pi.conversation_id
      WHERE COALESCE(pi.contact_id, c.contact_id) IS NOT NULL
        AND EXISTS (SELECT 1 FROM contacts ct WHERE ct.id = COALESCE(pi.contact_id, c.contact_id) AND ct.type <> 'company')
      ON CONFLICT (pipeline_item_id, contact_id) DO NOTHING
    SQL
    execute <<~SQL.squish
      UPDATE pipeline_items pi SET
        primary_contact_id = CASE WHEN COALESCE(pi.contact_id, c.contact_id) IN (SELECT id FROM contacts WHERE type <> 'company')
          THEN COALESCE(pi.contact_id, c.contact_id) ELSE NULL END,
        company_id = CASE WHEN COALESCE(pi.contact_id, c.contact_id) IN (SELECT id FROM contacts WHERE type = 'company')
          THEN COALESCE(pi.contact_id, c.contact_id) ELSE NULL END,
        owner_id = COALESCE(c.assignee_id, pi.assigned_by_id),
        title = COALESCE(NULLIF(pi.title, ''), 'Negócio - ' || COALESCE(
          (SELECT NULLIF(ct.name, '') FROM contacts ct WHERE ct.id = COALESCE(pi.contact_id, c.contact_id)),
          c.display_id::text, pi.id::text)),
        value = COALESCE(
          CASE WHEN (pi.custom_fields->>'value') ~ '^[0-9]+([.,][0-9]+)?$'
            THEN replace(pi.custom_fields->>'value', ',', '.')::numeric END,
          (SELECT COALESCE(SUM(CASE WHEN (service->>'value') ~ '^[0-9]+([.,][0-9]+)?$'
            THEN replace(service->>'value', ',', '.')::numeric ELSE 0 END), 0)
           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pi.custom_fields->'services') = 'array'
             THEN pi.custom_fields->'services' ELSE '[]'::jsonb END) service), 0),
        currency = COALESCE(NULLIF(pi.custom_fields->>'currency', ''), 'BRL'),
        notes = COALESCE(pi.notes, (SELECT sm.notes FROM stage_movements sm
          WHERE sm.pipeline_item_id = pi.id AND sm.notes IS NOT NULL ORDER BY sm.created_at DESC LIMIT 1))
      FROM conversations c WHERE c.id = pi.conversation_id
    SQL
    execute <<~SQL.squish
      UPDATE pipeline_items pi SET
        primary_contact_id = CASE WHEN ct.type <> 'company' THEN COALESCE(pi.primary_contact_id, pi.contact_id) ELSE pi.primary_contact_id END,
        company_id = CASE WHEN ct.type = 'company' THEN COALESCE(pi.company_id, pi.contact_id) ELSE pi.company_id END,
        owner_id = COALESCE(pi.owner_id, pi.assigned_by_id),
        title = COALESCE(NULLIF(pi.title, ''), 'Negócio - ' || COALESCE(NULLIF(ct.name, ''), pi.id::text)),
        currency = COALESCE(NULLIF(pi.currency, ''), 'BRL')
      FROM contacts ct WHERE ct.id = pi.contact_id
    SQL
    execute <<~SQL.squish
      UPDATE pipeline_items pi SET
        value = COALESCE(
          CASE WHEN (pi.custom_fields->>'value') ~ '^[0-9]+([.,][0-9]+)?$'
            THEN replace(pi.custom_fields->>'value', ',', '.')::numeric END,
          (SELECT COALESCE(SUM(CASE WHEN (service->>'value') ~ '^[0-9]+([.,][0-9]+)?$'
            THEN replace(service->>'value', ',', '.')::numeric ELSE 0 END), 0)
           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(pi.custom_fields->'services') = 'array'
             THEN pi.custom_fields->'services' ELSE '[]'::jsonb END) service), 0),
        notes = COALESCE(pi.notes, (SELECT sm.notes FROM stage_movements sm
          WHERE sm.pipeline_item_id = pi.id AND sm.notes IS NOT NULL ORDER BY sm.created_at DESC LIMIT 1))
    SQL
    execute "UPDATE pipeline_items SET title = 'Negócio - ' || id::text WHERE title IS NULL OR title = ''"
    change_column_null :pipeline_items, :title, false
  end

  def add_default_deal_attributes
    pipelines = select_all('SELECT id, custom_fields FROM pipelines')
    pipelines.each do |pipeline|
      fields = pipeline['custom_fields'].presence || {}
      parsed = fields.is_a?(String) ? JSON.parse(fields) : fields
      parsed['attributes'] = (Array(parsed['attributes']).map(&:to_s) + DEFAULT_DEAL_ATTRIBUTES).uniq
      execute "UPDATE pipelines SET custom_fields = #{connection.quote(parsed.to_json)}::jsonb WHERE id = #{connection.quote(pipeline['id'])}"
    end
  end
end
