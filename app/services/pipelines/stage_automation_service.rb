class Pipelines::StageAutomationService
  SUPPORTED_TRIGGERS = %w[label_added conversation_status_changed custom_attribute_updated].freeze
  SUPPORTED_ACTIONS  = %w[move_to_stage assign_agent apply_label].freeze

  def initialize(conversation, changed_attributes = {})
    @conversation       = conversation
    @changed_attributes = changed_attributes.with_indifferent_access
  end

  def perform
    Current.executed_by = :stage_automation
    @conversation.pipeline_items.includes(pipeline_stage: :pipeline).each do |pipeline_item|
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
      next unless rule_matches?(rule)

      execute_action(rule, pipeline_item)
    end
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
    when 'move_to_stage' then move_to_stage(pipeline_item, action_value)
    when 'assign_agent'  then assign_agent(action_value)
    when 'apply_label'   then apply_label(action_value)
    end
  rescue StandardError => e
    Rails.logger.error "[StageAutomation] conv=#{@conversation.id} action=#{rule[:action]}: #{e.message}"
  end

  def move_to_stage(pipeline_item, target_stage_id)
    return if target_stage_id.blank?
    return if pipeline_item.pipeline_stage_id.to_s == target_stage_id.to_s

    pipeline     = pipeline_item.pipeline_stage.pipeline
    target_stage = pipeline.pipeline_stages.find_by(id: target_stage_id)
    return unless target_stage

    Pipelines::ConversationService.new(pipeline: pipeline, user: nil)
                                  .move_to_stage(pipeline_item, target_stage)
    Rails.logger.info "[StageAutomation] conv=#{@conversation.id} moved to stage=#{target_stage.name}"
  end

  def assign_agent(agent_id)
    return if agent_id.blank?

    agent = User.find_by(id: agent_id)
    return unless agent

    @conversation.update!(assignee: agent)
    Rails.logger.info "[StageAutomation] conv=#{@conversation.id} assigned to agent=#{agent.name}"
  end

  def apply_label(label_title)
    return if label_title.blank?

    current_labels = @conversation.label_list
    return if current_labels.include?(label_title)

    @conversation.update!(label_list: current_labels + [label_title])
    Rails.logger.info "[StageAutomation] conv=#{@conversation.id} label=#{label_title} applied"
  end
end
