# frozen_string_literal: true

module ScheduledActionSerializer
  extend self

  def serialize(scheduled_action, **options)
    return nil unless scheduled_action

    {
      id: scheduled_action.id,
      deal_id: scheduled_action.canonical_deal_id,
      legacy_deal_id: scheduled_action.legacy_deal_id,
      contact_id: scheduled_action.contact_id,
      conversation_id: scheduled_action.conversation_id,
      action_type: scheduled_action.action_type,
      status: scheduled_action.status,
      scheduled_for: scheduled_action.scheduled_for&.iso8601,
      executed_at: scheduled_action.executed_at&.iso8601,
      payload: scheduled_action.payload || {},
      template_id: scheduled_action.template_id,
      created_by: scheduled_action.created_by,
      retry_count: scheduled_action.retry_count,
      max_retries: scheduled_action.max_retries,
      error_message: scheduled_action.error_message,
      recurrence_type: scheduled_action.recurrence_type,
      recurrence_config: scheduled_action.recurrence_config || {},
      time_until_execution: scheduled_action.time_until_execution,
      formatted_time_until: scheduled_action.formatted_time_until,
      overdue: scheduled_action.overdue?,
      can_retry: scheduled_action.can_retry?,
      creator: scheduled_action.creator ? {
        id: scheduled_action.creator.id,
        name: scheduled_action.creator.name,
        email: scheduled_action.creator.email
      } : nil,
      created_at: scheduled_action.created_at&.iso8601,
      updated_at: scheduled_action.updated_at&.iso8601
    }
  end

  def serialize_collection(scheduled_actions, **options)
    return [] unless scheduled_actions

    scheduled_actions.map { |action| serialize(action, **options) }
  end
end
