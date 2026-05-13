# == Schema Information
#
# Table name: automation_rule_runs
#
#  id                 :uuid             not null, primary key
#  duration_ms        :integer
#  error_message      :text
#  event_name         :string           not null
#  finished_at        :datetime
#  payload            :jsonb
#  started_at         :datetime         not null
#  status             :string           not null
#  steps              :jsonb
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  automation_rule_id :uuid             not null
#
# Indexes
#
#  index_automation_rule_runs_on_automation_rule_id   (automation_rule_id)
#  index_automation_rule_runs_on_rule_and_started_at  (automation_rule_id,started_at DESC)
#  index_automation_rule_runs_on_started_at           (started_at)
#  index_automation_rule_runs_on_status               (status)
#
# Foreign Keys
#
#  fk_rails_...  (automation_rule_id => automation_rules.id) ON DELETE => cascade
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
