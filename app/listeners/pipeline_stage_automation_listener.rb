class PipelineStageAutomationListener < BaseListener
  TRIGGER_KEYS = %w[label_list status custom_attributes].freeze

  def conversation_updated(event)
    return if event.data[:performed_by] == :stage_automation

    conversation       = event.data[:conversation]
    changed_attributes = event.data[:changed_attributes] || {}

    return unless relevant_change?(changed_attributes)
    return unless conversation.pipeline_items.exists?

    Pipelines::StageAutomationService.new(conversation, changed_attributes).perform
  rescue StandardError => e
    Rails.logger.error "[PipelineStageAutomationListener] conv=#{event.data.dig(:conversation, :id)}: #{e.message}"
  end

  private

  def relevant_change?(changed_attributes)
    (changed_attributes.keys & TRIGGER_KEYS).any?
  end
end
