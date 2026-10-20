class DealHistoryEvent < ApplicationRecord
  belongs_to :pipeline_item, optional: true
  belongs_to :actor, class_name: 'User', optional: true

  validates :action, :source, presence: true

  scope :chronological, -> { order(created_at: :asc) }

  def readonly?
    persisted?
  end

  def destroy
    raise ActiveRecord::ReadOnlyRecord, 'Deal history is append-only'
  end
end
