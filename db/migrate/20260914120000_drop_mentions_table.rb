# The mention feature had no producer, so the table is expected to be empty.
# `up` verifies that instead of assuming it.
class DropMentionsTable < ActiveRecord::Migration[7.1]
  # The enum no longer names this value, so it cannot be referenced by name.
  ORPHAN_NOTIFICATION_TYPE = 4

  def up
    # The count and the DELETE below are plain DML, so row-level security makes
    # them read 0 and delete 0 while still reporting success. Asked before the
    # drop, reported after it.
    filtered = %i[mentions notifications].select { |table| table_exists?(table) && row_security_active?(table) }

    if table_exists?(:mentions)
      # Non-zero only where rows came from a dump with bigint user ids.
      leftover = select_value('SELECT count(*) FROM mentions').to_i
      say "mentions: #{leftover} row(s) discarded" if leftover.positive?
    end

    drop_table :mentions, if_exists: true

    orphans = execute("DELETE FROM notifications WHERE notification_type = #{ORPHAN_NOTIFICATION_TYPE}").cmd_tuples
    say "notifications type #{ORPHAN_NOTIFICATION_TYPE} (conversation_mention): #{orphans} deleted" if orphans.positive?

    warn_row_security(filtered)
  end

  # Restores the table and its indexes, not the notifications `up` deleted.
  def down
    create_table :mentions, id: :uuid, default: -> { 'gen_random_uuid()' }, force: :cascade do |t|
      t.uuid :user_id, null: false
      t.uuid :conversation_id, null: false
      t.datetime :mentioned_at, precision: nil, null: false
      t.datetime :created_at, precision: nil, null: false
      t.datetime :updated_at, precision: nil, null: false
      t.index [:conversation_id], name: 'index_mentions_on_conversation_id'
      t.index %i[user_id conversation_id], name: 'index_mentions_on_user_id_and_conversation_id', unique: true
      t.index [:user_id], name: 'index_mentions_on_user_id'
    end
  end

  private

  def row_security_active?(table)
    select_value("SELECT row_security_active(#{quote(table.to_s)})")
  end

  def warn_row_security(filtered)
    return if filtered.blank?

    say "WARNING: row-level security filters #{filtered.join(', ')} for role #{select_value('SELECT current_user')}. " \
        'The counts above cover only the rows this role can read, and the DELETE removed only those. ' \
        'Re-run the notifications cleanup as a role that bypasses RLS if orphan rows may exist.'
  end
end
