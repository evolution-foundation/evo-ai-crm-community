class Internal::DeleteAccountsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
  end
end
