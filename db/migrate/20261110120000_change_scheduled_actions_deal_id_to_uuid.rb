# deal_id names a pipeline card, whose id is a uuid, but the column was a bigint:
# Rails cast "3571c2d1-..." to 3571 and any id starting with a letter to 0. The
# stored values point at no card and cannot be mapped back, so they are cleared.
class ChangeScheduledActionsDealIdToUuid < ActiveRecord::Migration[7.1]
  def up
    change_column :scheduled_actions, :deal_id, :uuid, using: 'NULL::uuid'
  end

  def down
    change_column :scheduled_actions, :deal_id, :bigint, using: 'NULL::bigint'
  end
end
