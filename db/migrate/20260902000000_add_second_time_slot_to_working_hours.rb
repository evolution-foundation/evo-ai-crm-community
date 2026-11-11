class AddSecondTimeSlotToWorkingHours < ActiveRecord::Migration[7.1]
  # Idempotent: db/schema.rb already contains these columns (it is dumped after this
  # migration ran). On a fresh database `db:prepare` loads the schema first, so a plain
  # add_column would fail with PG::DuplicateColumn. Only add what is still missing.
  COLUMNS = {
    open_hour_2: :integer,
    open_minutes_2: :integer,
    close_hour_2: :integer,
    close_minutes_2: :integer
  }.freeze

  def change
    COLUMNS.each do |column, type|
      add_column :working_hours, column, type unless column_exists?(:working_hours, column)
    end
  end
end
