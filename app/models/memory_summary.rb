class MemorySummary < ApplicationRecord
  validates :app_name, :user_id, :content, presence: true

  scope :for, ->(app_name:, user_id:) { where(app_name: app_name, user_id: user_id).order(created_at: :desc) }
end
