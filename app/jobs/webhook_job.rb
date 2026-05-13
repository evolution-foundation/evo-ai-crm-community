class WebhookJob < ApplicationJob
  queue_as :medium
  # Webhook types: :account_webhook (default), :inbox_webhook, :agent_bot,
  # :api_inbox_webhook, :macro_webhook. Only :macro_webhook re-raises on
  # failure so Sidekiq surfaces the error; others swallow-and-warn per the
  # legacy contract (see lib/webhooks/trigger.rb#execute).
  def perform(url, payload, webhook_type = :account_webhook)
    Webhooks::Trigger.execute(url, payload, webhook_type)
  end
end
