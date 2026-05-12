# frozen_string_literal: true

# == Schema Information
#
# Table name: scheduled_actions
#
#  id                   :bigint           not null, primary key
#  action_type          :string(50)       not null
#  created_by           :uuid             not null
#  error_message        :text
#  executed_at          :datetime
#  max_retries          :integer          default(3)
#  notification_sent_at :datetime
#  payload              :jsonb            not null
#  recurrence_config    :jsonb
#  recurrence_type      :string(20)
#  retry_count          :integer          default(0)
#  scheduled_for        :datetime         not null
#  status               :string(20)       default("scheduled"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  contact_id           :uuid
#  conversation_id      :uuid
#  deal_id              :bigint
#  notify_user_id       :uuid
#  template_id          :bigint
#
# Indexes
#
#  idx_scheduled_actions_contact_status        (contact_id,status)
#  idx_scheduled_actions_deal_status           (deal_id,status)
#  idx_scheduled_actions_status_time           (status,scheduled_for)
#  index_scheduled_actions_on_action_type      (action_type)
#  index_scheduled_actions_on_contact_id       (contact_id)
#  index_scheduled_actions_on_conversation_id  (conversation_id)
#  index_scheduled_actions_on_deal_id          (deal_id)
#  index_scheduled_actions_on_notify_user_id   (notify_user_id)
#  index_scheduled_actions_on_scheduled_for    (scheduled_for)
#  index_scheduled_actions_on_status           (status)
#
# Foreign Keys
#
#  fk_rails_...  (contact_id => contacts.id) ON DELETE => cascade
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#

class ScheduledAction < ApplicationRecord
  # Associations
  belongs_to :contact, optional: true
  belongs_to :conversation, optional: true
  belongs_to :creator, class_name: 'User', foreign_key: :created_by
  belongs_to :notifier, class_name: 'User', foreign_key: :notify_user_id, optional: true
  has_many :execution_logs, class_name: 'ScheduledActionExecutionLog', dependent: :destroy_async
  has_many :notifications, class_name: 'ScheduledActionNotification', dependent: :destroy_async

  # Enums
  ACTION_TYPES = %w[
    send_message
    send_email
    execute_webhook
    trigger_journey
    create_task
    update_deal_stage
    add_deal_note
    send_whatsapp
    send_sms
  ].freeze

  STATUSES = %w[
    scheduled
    executing
    completed
    failed
    cancelled
  ].freeze

  RECURRENCE_TYPES = %w[
    once
    daily
    weekly
    monthly
  ].freeze

  # Validations
  validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :scheduled_for, presence: true
  validates :created_by, presence: true
  validates :payload, presence: true
  validates :recurrence_type, inclusion: { in: RECURRENCE_TYPES }, allow_nil: true

  validate :scheduled_for_cannot_be_in_past, on: :create
  validate :at_least_one_target_present

  # Scopes
  scope :for_deal, ->(deal_id) { where(deal_id: deal_id) }
  scope :for_contact, ->(contact_id) { where(contact_id: contact_id) }
  scope :for_conversation, ->(conversation_id) { where(conversation_id: conversation_id) }
  scope :by_action_type, ->(type) { where(action_type: type) }
  scope :by_status, ->(status) { where(status: status) }
  scope :scheduled, -> { where(status: 'scheduled') }
  scope :executing, -> { where(status: 'executing') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :cancelled, -> { where(status: 'cancelled') }
  scope :due, -> { scheduled.where('scheduled_for <= ?', Time.current) }
  scope :upcoming, -> { scheduled.where('scheduled_for > ?', Time.current) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_scheduled_time, -> { order(scheduled_for: :asc) }
  scope :retriable, -> { failed.where('retry_count < max_retries') }

  # State machine methods
  def mark_as_executing!
    update!(status: 'executing')
  end

  def mark_as_completed!(executed_at = Time.current)
    update!(
      status: 'completed',
      executed_at: executed_at,
      error_message: nil
    )
  end

  def mark_as_failed!(error)
    update!(
      status: 'failed',
      error_message: error.to_s,
      retry_count: retry_count + 1
    )
  end

  def mark_as_cancelled!
    update!(status: 'cancelled')
  end

  # Status checks
  def scheduled?
    status == 'scheduled'
  end

  def executing?
    status == 'executing'
  end

  def completed?
    status == 'completed'
  end

  def failed?
    status == 'failed'
  end

  def cancelled?
    status == 'cancelled'
  end

  def can_retry?
    failed? && retry_count < max_retries
  end

  def overdue?
    scheduled? && scheduled_for < Time.current
  end

  def due_soon?(minutes = 60)
    scheduled? && scheduled_for <= minutes.minutes.from_now
  end

  # Recurrence
  def recurring?
    recurrence_type.present? && recurrence_type != 'once'
  end

  def create_next_occurrence
    return unless recurring? && completed?

    next_scheduled_time = calculate_next_scheduled_time
    return if next_scheduled_time.nil?

    ScheduledAction.create!(
      deal_id: deal_id,
      contact_id: contact_id,
      conversation_id: conversation_id,
      action_type: action_type,
      scheduled_for: next_scheduled_time,
      payload: payload,
      template_id: template_id,
      created_by: created_by,
      max_retries: max_retries,
      journey_session_id: journey_session_id,
      recurrence_type: recurrence_type,
      recurrence_config: recurrence_config
    )
  end

  # Time helpers
  def time_until_execution
    return 0 if overdue?

    (scheduled_for - Time.current).to_i
  end

  def formatted_time_until
    return 'Overdue' if overdue?

    seconds = time_until_execution
    if seconds < 60
      "#{seconds}s"
    elsif seconds < 3600
      "#{seconds / 60}m"
    elsif seconds < 86_400
      "#{seconds / 3600}h"
    else
      "#{seconds / 86_400}d"
    end
  end

  private

  def scheduled_for_cannot_be_in_past
    return unless scheduled_for.present? && scheduled_for < Time.current

    errors.add(:scheduled_for, 'cannot be in the past')
  end

  def at_least_one_target_present
    return if deal_id.present? || contact_id.present? || conversation_id.present?

    errors.add(:base, 'must have at least one target (deal, contact, or conversation)')
  end

  def calculate_next_scheduled_time
    case recurrence_type
    when 'daily'
      scheduled_for + 1.day
    when 'weekly'
      scheduled_for + 1.week
    when 'monthly'
      scheduled_for + 1.month
    else
      nil
    end
  end
end

