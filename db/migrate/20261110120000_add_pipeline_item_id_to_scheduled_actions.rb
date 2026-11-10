# frozen_string_literal: true

# The card of a scheduled action by its uuid. `deal_id` stays a bigint because
# existing callers still write and read it.
class AddPipelineItemIdToScheduledActions < ActiveRecord::Migration[7.1]
  include ConcurrentIndexMigration

  disable_ddl_transaction!

  INDEX_NAME = 'index_scheduled_actions_on_pipeline_item_id'

  def up
    add_column :scheduled_actions, :pipeline_item_id, :uuid, if_not_exists: true
    add_index_concurrently :scheduled_actions, :pipeline_item_id, name: INDEX_NAME
  end

  def down
    remove_index :scheduled_actions, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    remove_column :scheduled_actions, :pipeline_item_id, if_exists: true
  end
end
