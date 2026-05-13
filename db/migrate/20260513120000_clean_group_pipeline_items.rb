# frozen_string_literal: true

class CleanGroupPipelineItems < ActiveRecord::Migration[7.1]
  def up
    execute <<-SQL
      DELETE FROM pipeline_items
      WHERE contact_id IN (
        SELECT id FROM contacts WHERE type = 'group'
      )
      AND conversation_id IS NULL;
    SQL
  end

  def down
    # Intentionally irreversible: removed pipeline associations for group contacts cannot be recovered.
  end
end
