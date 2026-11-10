# The card of a scheduled action by its uuid. `deal_id` stays as it is: it is a
# bigint, so it cannot hold a card id, but existing callers still write and read it.
class AddPipelineItemIdToScheduledActions < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduled_actions, :pipeline_item_id, :uuid
    add_index :scheduled_actions, :pipeline_item_id
  end
end
