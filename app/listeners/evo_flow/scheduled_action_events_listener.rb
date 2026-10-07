# frozen_string_literal: true

module EvoFlow
  # Subscribes to Wisper :scheduled_action_outcome (ScheduledAction, when its
  # status becomes completed or failed) and forwards it to evo-flow, so the
  # outcome shows on the contact's events timeline.
  # `evo_flow_enabled?` is duplicated across the EvoFlow listeners on purpose.
  class ScheduledActionEventsListener
    TRACK_PATH = '/events/track'
    EXECUTED_EVENT_NAME = 'scheduled_action.executed'
    FAILED_EVENT_NAME = 'scheduled_action.failed'
    SOURCE = 'scheduled_action'
    MAX_ERROR_MESSAGE = 500

    def scheduled_action_outcome(data)
      return if data.respond_to?(:data)

      event_data = data[:data] || data
      action = event_data[:scheduled_action]
      unless action
        Rails.logger.error('EvoFlow::ScheduledActionEventsListener#scheduled_action_outcome: scheduled_action is nil')
        return
      end
      return unless evo_flow_enabled?

      contact_id = resolve_contact_id(action)
      return warn_unresolved(action) unless contact_id

      enqueue_track(action, contact_id)
    rescue StandardError => e
      log_failure(__method__, e)
    end

    private

    def resolve_contact_id(action)
      action.contact_id || action.conversation&.contact_id
    end

    def enqueue_track(action, contact_id)
      event_name = action.completed? ? EXECUTED_EVENT_NAME : FAILED_EVENT_NAME
      # retry_count tells one failed attempt from the next; Sidekiq retries of
      # the publish keep the same id.
      source_event_uuid = "#{action.id}.#{action.status}.#{action.retry_count}"
      message_id = EvoFlow::PayloadBuilder.message_id_for(event_name, contact_id, source_event_uuid)
      payload = EvoFlow::PayloadBuilder.build_track(
        event_name: event_name,
        contact_id: contact_id,
        properties: build_properties(action),
        occurred_at: action.updated_at,
        message_id: message_id
      )
      EvoFlow::PublishEventWorker.perform_async(TRACK_PATH, JSON.parse(payload.to_json), current_tenant_id)
    end

    # Optional fields that resolve to nil are OMITTED, never sent as null —
    # the evo-flow schema pipe rejects explicit null for typed fields.
    def build_properties(action)
      properties = {
        scheduled_action_id: action.id,
        action_type: action.action_type,
        scheduled_for: action.scheduled_for.utc.iso8601,
        source: SOURCE,
        conversation_id: action.conversation_id
      }
      properties.merge!(action.completed? ? executed_properties(action) : failed_properties(action))
      properties.compact
    end

    def executed_properties(action)
      { executed_at: action.executed_at&.utc&.iso8601 }
    end

    def failed_properties(action)
      {
        error_message: action.error_message.presence&.truncate(MAX_ERROR_MESSAGE),
        retry_count: action.retry_count.to_i,
        will_retry: action.can_retry?
      }
    end

    def warn_unresolved(action)
      Rails.logger.warn(
        "EvoFlow::ScheduledActionEventsListener#scheduled_action_outcome: no resolvable contact_id for scheduled_action #{action.id}"
      )
      nil
    end

    def evo_flow_enabled?
      EvoFlow.enabled?
    end

    def log_failure(handler, error)
      tag = enqueue_loss?(error) ? '[EvoFlow][enqueue-loss]' : '[EvoFlow]'
      Rails.logger.error(
        "#{tag} EvoFlow::ScheduledActionEventsListener##{handler} failed: #{error.class}: #{error.message}"
      )
      Sentry.capture_exception(error) if defined?(Sentry)
      nil
    end

    def enqueue_loss?(error)
      return true if defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)

      error.is_a?(ArgumentError) && error.message.include?('occurred_at is required')
    end

    # The scheduled-action job runs bound to the action's tenant; the seam hands
    # it over so the publish carries X-Evo-Tenant-Id. Community: nil, no header.
    def current_tenant_id
      EvoExtensionPoints::RuntimeContext.current_scope_id
    end
  end
end
