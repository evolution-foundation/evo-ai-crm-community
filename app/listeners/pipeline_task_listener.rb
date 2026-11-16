class PipelineTaskListener < BaseListener
  def pipeline_task_created(event)
    task = extract_task(event)

    return unless task

    # Webhook first: a failing notification must not hold the event back.
    dispatch_webhook_event('pipeline_task.created', task)

    return if task.assigned_to.blank?

    PipelineTasks::NotificationService.new(
      task: task,
      notification_type: :pipeline_task_assigned
    ).perform
  end

  def pipeline_task_completed(event)
    task = extract_task(event)

    return unless task

    # Send completion notification to creator if different from completer
    completed_by_id = task.metadata['completed_by_id']
    if task.created_by_id != completed_by_id && completed_by_id.present?
      PipelineTasks::NotificationService.new(
        task: task,
        notification_type: :pipeline_task_completed
      ).perform
    end

    # Dispatch webhook event
    dispatch_webhook_event('pipeline_task.completed', task)
  end

  def pipeline_task_overdue(event)
    task = extract_task(event)

    return unless task

    # Notification already sent in job
    # Just dispatch webhook
    dispatch_webhook_event('pipeline_task.overdue', task)
  end

  def pipeline_task_updated(event)
    task = extract_task(event)

    return unless task

    # Dispatch webhook event
    dispatch_webhook_event('pipeline_task.updated', task)
  end

  def pipeline_task_cancelled(event)
    task = extract_task(event)

    return unless task

    # Dispatch webhook event
    dispatch_webhook_event('pipeline_task.cancelled', task)
  end

  private

  def extract_task(event)
    # Handle both Wisper (Hash) and EventDispatcher (Events::Base) formats
    if event.respond_to?(:data)
      # EventDispatcher format - Events::Base object
      event.data[:task]
    else
      # Wisper format - Hash
      event[:task] || event['task']
    end
  end

  def dispatch_webhook_event(event_name, task)
    payload = {
      event: event_name,
      task_id: task.id,
      pipeline_item_id: task.pipeline_item_id,
      title: task.title,
      task_type: task.task_type,
      status: task.status,
      priority: task.priority,
      due_date: task.due_date,
      assigned_to_id: task.assigned_to_id,
      created_at: task.created_at,
      completed_at: task.completed_at
    }

    deliver_to_account_webhooks(event_name, payload, task.pipeline_item&.conversation&.inbox_id)
  rescue StandardError => e
    Rails.logger.error "[PipelineTaskListener] Error dispatching webhook: #{e.message}"
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  def deliver_to_account_webhooks(event_name, payload, inbox_id)
    Webhook.account_type.each do |webhook|
      next unless webhook.subscriptions.include?(event_name)
      next if inbox_id.present? && webhook.inbox_id.present? && webhook.inbox_id != inbox_id

      WebhookJob.perform_later(webhook.url, payload)
    end
  end
end
