class MemoryEvent < ApplicationRecord
  validates :app_name, :user_id, :role, :content, presence: true

  scope :for, ->(app_name:, user_id:) { where(app_name: app_name, user_id: user_id).order(created_at: :asc) }

  def self.trim_to!(app_name:, user_id:, max_messages:)
    scope = self.for(app_name: app_name, user_id: user_id)
    excess = scope.count - max_messages
    return 0 if excess <= 0

    ids_to_delete = scope.limit(excess).pluck(:id)
    where(id: ids_to_delete).delete_all
  end
end
