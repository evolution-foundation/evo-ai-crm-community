class Account::ConversationsResolutionSchedulerJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    auto_resolve_duration = GlobalConfigService.load('AUTO_RESOLVE_DURATION', nil)&.to_i
    return if auto_resolve_duration.nil? || auto_resolve_duration.zero?

    resolvable_conversations = Conversation.open
                                           .where('last_activity_at < ?', Time.now.utc - auto_resolve_duration.minutes)
                                           .limit(Limits::BULK_ACTIONS_LIMIT)

    resolvable_conversations.each(&:toggle_status)
  end
end
Account::ConversationsResolutionSchedulerJob.prepend_mod_with('Account::ConversationsResolutionSchedulerJob')
