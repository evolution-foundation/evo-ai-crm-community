# == Schema Information
#
# Table name: automation_rule_runs
#
#  id                 :uuid             not null, primary key
#  automation_rule_id :uuid             not null
#  event_name         :string           not null
#  status             :string           not null
#  started_at         :datetime         not null
#  finished_at        :datetime
#  duration_ms        :integer
#  error_message      :text
#  payload            :jsonb            default({})
#  steps              :jsonb            default([])
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class AutomationRuleRun < ApplicationRecord
  STATUSES = %w[matched no_match error skipped].freeze

  belongs_to :automation_rule

  validates :event_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(started_at: :desc) }
  scope :with_status, ->(status) { where(status: status) if status.present? }

  def self.retention_days
    ENV.fetch('AUTOMATION_RULE_RUNS_RETENTION_DAYS', 30).to_i
  end
end
