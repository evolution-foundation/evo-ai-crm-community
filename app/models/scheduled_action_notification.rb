# frozen_string_literal: true

# == Schema Information
#
# Table name: scheduled_action_notifications
#
#  id                  :bigint           not null, primary key
#  error_details       :text
#  message             :text
#  notification_type   :string(20)       not null
#  status              :string(20)       default("pending"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  scheduled_action_id :bigint           not null
#  user_id             :uuid             not null
#
# Indexes
#
#  idx_notifications_action_type                                (scheduled_action_id,notification_type)
#  idx_notifications_user_date                                  (user_id,created_at)
#  index_scheduled_action_notifications_on_notification_type    (notification_type)
#  index_scheduled_action_notifications_on_scheduled_action_id  (scheduled_action_id)
#  index_scheduled_action_notifications_on_status               (status)
#  index_scheduled_action_notifications_on_user_id              (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (scheduled_action_id => scheduled_actions.id) ON DELETE => cascade
#

class ScheduledActionNotification < ApplicationRecord
  # Associations
  belongs_to :scheduled_action
  belongs_to :user

  # Enums
  NOTIFICATION_TYPES = %w[success failure retry].freeze
  STATUSES = %w[pending sent failed].freeze

  # Validations
  validates :scheduled_action_id, presence: true
  validates :user_id, presence: true
  validates :notification_type, presence: true, inclusion: { in: NOTIFICATION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }

  # Scopes
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :for_action, ->(action_id) { where(scheduled_action_id: action_id) }
  scope :by_type, ->(type) { where(notification_type: type) }
  scope :by_status, ->(status) { where(status: status) }
  scope :pending, -> { where(status: 'pending') }
  scope :sent, -> { where(status: 'sent') }
  scope :failed, -> { where(status: 'failed') }
  scope :success_notifications, -> { where(notification_type: 'success') }
  scope :failure_notifications, -> { where(notification_type: 'failure') }
  scope :recent, -> { order(created_at: :desc) }
  scope :unread, -> { where(status: 'pending') }

  # Instance methods
  def success?
    notification_type == 'success'
  end

  def failure?
    notification_type == 'failure'
  end

  def retry?
    notification_type == 'retry'
  end

  def pending?
    status == 'pending'
  end

  def sent?
    status == 'sent'
  end

  def mark_as_sent!
    update!(status: 'sent')
  end

  def mark_as_failed!(error)
    update!(
      status: 'failed',
      error_details: error.to_s
    )
  end
end
