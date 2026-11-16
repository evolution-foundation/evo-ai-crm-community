# housekeeping
# ensure stale ONLINE PRESENCE KEYS for contacts are removed periodically
# should result in 50% redis mem size reduction

class Internal::RemoveStaleRedisKeysJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Rails.logger.info "Enqueuing ProcessStaleRedisKeysJob"
    Internal::ProcessStaleRedisKeysJob.perform_later
  end
end
