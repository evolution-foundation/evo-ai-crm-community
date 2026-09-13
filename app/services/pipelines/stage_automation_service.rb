class Pipelines::StageAutomationService
  include Pipelines::StageMessageActions

  # `inactivity` is accepted at save-time (controller validates against this
  # list) but is NOT fired here — it is time-based and handled by
  # Pipelines::StageInactivityActionsService. The event path skips it.
  SUPPORTED_TRIGGERS = %w[label_added conversation_status_changed custom_attribute_updated inactivity].freeze
  SUPPORTED_ACTIONS  = %w[
    move_to_stage move_to_pipeline assign_agent assign_team apply_label remove_label
    change_priority change_status send_ai_message send_direct_message send_template
    finalize send_webhook_event create_pipeline_task
    send_canned_response send_email_to_team send_email_transcript update_custom_attribute
  ].freeze
  INACTIVITY_TRIGGER = 'inactivity'.freeze

  def initialize(conversation, changed_attributes = {})
    @conversation       = conversation
    @changed_attributes = changed_attributes.with_indifferent_access
  end

  def perform
    Current.executed_by = :stage_automation
    @conversation.pipeline_items.includes(pipeline_stage: :pipeline).find_each do |pipeline_item|
      next if log_and_skip_archived_pipeline(pipeline_item)

      evaluate_stage_rules(pipeline_item)
    end
  ensure
    Current.reset
  end

  private

  def evaluate_stage_rules(pipeline_item)
    rules = pipeline_item.pipeline_stage.automation_rules&.dig('rules')
    return if rules.blank?

    rules.each do |rule|
      rule = rule.with_indifferent_access
      next unless SUPPORTED_TRIGGERS.include?(rule[:trigger])
      next if rule[:trigger] == INACTIVITY_TRIGGER # time-based; fired elsewhere
      next unless rule_matches?(rule)

      execute_action(rule, pipeline_item)
    end
  end

  # An archived pipeline must stop acting on its own — its rules can send messages to the
  # customer, and the operator can no longer even see the board. Evaluated per item, not
  # per conversation: a conversation may sit in several pipelines, and one archived among
  # them must not silence the active ones.
  def log_and_skip_archived_pipeline(pipeline_item)
    pipeline = pipeline_item.pipeline_stage.pipeline
    return false if pipeline.nil? || pipeline.is_active

    Rails.logger.warn(
      "[StageAutomation] conv=#{@conversation.id} item=#{pipeline_item.id} skipped: " \
      "pipeline #{pipeline.id} is archived (is_active=false)"
    )
    true
  end

  def rule_matches?(rule)
    case rule[:trigger]
    when 'label_added'
      label_added_match?(rule[:trigger_value])
    when 'conversation_status_changed'
      status_changed_to_match?(rule[:trigger_value])
    when 'custom_attribute_updated'
      @changed_attributes.key?('custom_attributes')
    else
      false
    end
  end

  def label_added_match?(trigger_value)
    return false unless @changed_attributes.key?('label_list')

    old_labels, new_labels = @changed_attributes['label_list']
    added = Array(new_labels) - Array(old_labels)
    return false if added.empty?

    trigger_value.blank? || added.include?(trigger_value)
  end

  def status_changed_to_match?(trigger_value)
    return false unless @changed_attributes.key?('status')

    _, new_status = @changed_attributes['status']
    trigger_value.blank? || new_status.to_s == trigger_value.to_s
  end

  def execute_action(rule, pipeline_item)
    action       = rule[:action]
    action_value = rule[:action_value]
    return unless SUPPORTED_ACTIONS.include?(action)

    case action
    when 'move_to_stage'           then move_to_stage(pipeline_item, action_value)
    when 'move_to_pipeline'        then move_to_pipeline(pipeline_item, action_value)
    when 'assign_agent'            then assign_agent(action_value)
    when 'assign_team'             then assign_team(@conversation, action_value)
    when 'apply_label'             then apply_label(action_value)
    when 'remove_label'            then remove_label(@conversation, action_value)
    when 'change_priority'         then change_priority(@conversation, action_value)
    when 'change_status'           then change_status(@conversation, action_value)
    when 'send_ai_message'         then send_ai_message(@conversation, suggested_message: rule[:ai_message])
    when 'send_direct_message'     then send_direct_message(@conversation, action_value)
    when 'send_template'           then send_template(@conversation, template_params_for(rule))
    when 'finalize'                then finalize(@conversation, action_value)
    when 'send_webhook_event'      then send_webhook_event(@conversation, action_value)
    when 'create_pipeline_task'    then create_pipeline_task(pipeline_item, action_value)
    when 'send_canned_response'    then send_canned_response(@conversation, action_value)
    when 'send_email_to_team'      then send_email_to_team(@conversation, action_value)
    when 'send_email_transcript'   then send_email_transcript(@conversation, action_value)
    when 'update_custom_attribute' then update_custom_attribute(@conversation, pipeline_item, action_value)
    end
  rescue StandardError => e
    Rails.logger.error "[StageAutomation] conv=#{@conversation.id} action=#{rule[:action]}: #{e.message}"
  end

  def assign_agent(agent_id)
    super(@conversation, agent_id)
  end

  def apply_label(label_value)
    super(@conversation, label_value)
  end
end
