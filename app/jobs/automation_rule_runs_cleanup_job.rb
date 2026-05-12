class AutomationRuleRunsCleanupJob < ApplicationJob
  queue_as :low

  def perform
    retention_days = AutomationRuleRun.retention_days
    return if retention_days <= 0

    cutoff = retention_days.days.ago
    deleted = AutomationRuleRun.where('started_at < ?', cutoff).delete_all
    Rails.logger.info "[AutomationRuleRunsCleanupJob] removed #{deleted} run(s) older than #{retention_days} day(s)"
    deleted
  end
end
