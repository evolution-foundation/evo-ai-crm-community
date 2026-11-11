class AddLabelToDataImports < ActiveRecord::Migration[7.1]
  def change
    # Optional tag name applied to every contact successfully imported by
    # this batch (contacts import UX request: "quero subir com uma TAG
    # especifica" — the import CSV template has no tag column, and there
    # was no way to bulk-tag the whole batch at import time).
    add_column :data_imports, :label, :string, if_not_exists: true
  end
end
