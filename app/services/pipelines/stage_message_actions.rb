require 'securerandom'

# Shared send handlers for stage automation actions, usable by BOTH the
# event-driven path (Pipelines::StageAutomationService) and the time-based
# inactivity path (Pipelines::StageInactivityActionsService). Each handler
# takes an already-resolved Conversation as its target.
module Pipelines::StageMessageActions
  AUTOMATION_SOURCE = 'stage_inactivity_action'.freeze

  # Ask the inbox's evo_ai agent bot to generate a contextual re-engagement
  # message. Falls back to a direct message when no evo_ai bot is available and
  # a literal text was provided. Mirrors AgentBots::InactivityActionsService.
  def send_ai_message(conversation, suggested_message: nil, source: AUTOMATION_SOURCE)
    agent_bot = conversation.inbox&.agent_bot
    unless agent_bot&.evo_ai_provider?
      if suggested_message.present?
        Rails.logger.info '[StageMessageActions] no evo_ai bot on inbox, falling back to direct message'
        return send_direct_message(conversation, suggested_message, source: source)
      end
      Rails.logger.warn "[StageMessageActions] send_ai_message skipped: inbox #{conversation.inbox_id} has no evo_ai bot and no fallback text"
      return false
    end

    agent_bot_inbox = conversation.inbox.agent_bot_inbox
    if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(conversation))
      Rails.logger.warn "[StageMessageActions] send_ai_message skipped: conv #{conversation.id}: #{skip_reason}"
      return false
    end

    AgentBots::HttpRequestService.new(agent_bot, build_ai_payload(conversation, suggested_message)).perform
    true
  end

  def send_direct_message(conversation, text, source: AUTOMATION_SOURCE)
    return false if text.blank?

    build_outgoing_message(conversation, text, source)
    true
  end

  # template_params: Hash with `id` (preferred) or `name`+`language`+`namespace`
  # +`processed_params`. Resolved/rendered by MessageBuilder + SendResolver.
  def send_template(conversation, template_params, source: AUTOMATION_SOURCE)
    return false if template_params.blank?

    ::Messages::MessageBuilder.new(
      nil, conversation,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: '',
      template_params: template_params,
      content_attributes: { automation_source: source }
    ).perform
    true
  end

  def finalize(conversation, text = nil, source: "#{AUTOMATION_SOURCE}_finalize")
    return false unless conversation

    conversation.resolved! unless conversation.resolved?
    build_outgoing_message(conversation, text, source) if text.present?
    true
  end

  # Shared with the time-based inactivity path so a rule like "inactive for
  # 30 minutes -> move to stage X" actually moves the item, not just the
  # event-driven triggers (label_added, conversation_status_changed, etc).
  def move_to_stage(pipeline_item, target_stage_id)
    return if target_stage_id.blank?
    return if pipeline_item.pipeline_stage_id.to_s == target_stage_id.to_s

    pipeline     = pipeline_item.pipeline_stage.pipeline
    target_stage = pipeline.pipeline_stages.find_by(id: target_stage_id)
    return unless target_stage

    Pipelines::ConversationService.new(pipeline: pipeline, user: nil)
                                  .move_to_stage(pipeline_item, target_stage)
    Rails.logger.info "[StageMessageActions] item=#{pipeline_item.id} moved to stage=#{target_stage.name}"
  end

  # Move the pipeline_item to a different pipeline by updating its pipeline_id
  # and pipeline_stage_id in place. Preserves the row's primary key, entered_at,
  # custom_fields, stage_movements history and tasks. Skipped silently when the
  # conversation already has another item in the destination pipeline (the
  # (conversation_id, pipeline_id) unique index would otherwise reject the
  # update).
  def move_to_pipeline(pipeline_item, action_value)
    target_pipeline_id, target_stage_id = parse_move_to_pipeline_value(action_value)
    return if target_pipeline_id.blank?
    return if pipeline_item.pipeline_id.to_s == target_pipeline_id.to_s

    target_pipeline = Pipeline.find_by(id: target_pipeline_id)
    return unless target_pipeline

    # Refusing the move leaves the conversation where it is, visible. Allowing it would
    # push the conversation into a board the operator archived and can no longer see.
    unless target_pipeline.is_active
      Rails.logger.warn "[StageMessageActions] item=#{pipeline_item.id} move_to_pipeline skipped: pipeline #{target_pipeline.id} is archived (is_active=false)"
      return
    end

    target_stage =
      if target_stage_id.present?
        target_pipeline.pipeline_stages.find_by(id: target_stage_id)
      else
        target_pipeline.pipeline_stages.ordered&.first || target_pipeline.pipeline_stages.first
      end
    return unless target_stage

    return if pipeline_item_already_in_pipeline?(pipeline_item, target_pipeline)

    old_stage = pipeline_item.pipeline_stage

    pipeline_item.update!(pipeline_id: target_pipeline.id, pipeline_stage_id: target_stage.id)

    begin
      pipeline_item.stage_movements.create!(
        from_stage: old_stage,
        to_stage: target_stage,
        moved_by: Current.user,
        movement_type: 'cross_pipeline',
        notes: "Moved from pipeline '#{old_stage&.pipeline&.name}' to '#{target_pipeline.name}'"
      )
    rescue StandardError => e
      Rails.logger.error "[StageMessageActions] move_to_pipeline stage_movement create! failed: #{e.message}"
    end

    Rails.logger.info "[StageMessageActions] item=#{pipeline_item.id} moved to pipeline=#{target_pipeline.name} stage=#{target_stage.name}"
  end

  def assign_agent(conversation, agent_id)
    return if agent_id.blank?

    agent = User.find_by(id: agent_id)
    return unless agent

    conversation.update!(assignee: agent)
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} assigned to agent=#{agent.name}"
  end

  def assign_team(conversation, team_id)
    return if team_id.blank?

    team = Team.find_by(id: team_id)
    return unless team

    conversation.update!(team_id: team.id)
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} assigned to team=#{team.name}"
  end

  def apply_label(conversation, label_value)
    return if label_value.blank?

    title = resolve_label_title(label_value)
    return if title.blank?

    current_labels = conversation.label_list
    return if current_labels.include?(title)

    conversation.update!(label_list: current_labels + [title])
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} label=#{title} applied"
  end

  def remove_label(conversation, label_value)
    return if label_value.blank?

    title = resolve_label_title(label_value)
    return if title.blank?

    current_labels = conversation.label_list
    return unless current_labels.include?(title)

    conversation.update!(label_list: current_labels - [title])
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} label=#{title} removed"
  end

  def change_priority(conversation, priority)
    return if priority.blank?

    priority_val = %w[nil none 0].include?(priority.to_s) ? nil : priority.to_s
    conversation.update!(priority: priority_val)
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} priority changed to #{priority_val}"
  end

  def change_status(conversation, status)
    return if status.blank?

    conversation.update!(status: status.to_s)
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} status changed to #{status}"
  end

  def send_webhook_event(conversation, webhook_url)
    return if webhook_url.blank?

    clean_url = webhook_url.to_s.strip
    payload = conversation.webhook_data.merge(event: 'automation_event.pipeline_stage_automation')
    WebhookJob.perform_later(clean_url, payload)
    Rails.logger.info "[StageMessageActions] conv=#{conversation.id} webhook dispatched to #{clean_url}"
  end

  def create_pipeline_task(pipeline_item, task_title)
    return if task_title.blank?

    creator = Current.user || User.where(type: 'SuperAdmin').first
    pipeline_item.tasks.create!(
      created_by: creator,
      title: task_title.to_s.strip,
      task_type: 'other',
      priority: 'medium'
    )
    Rails.logger.info "[StageMessageActions] item=#{pipeline_item.id} task created: #{task_title}"
  end

  private

  def parse_move_to_pipeline_value(value)
    return [nil, nil] if value.blank?

    case value
    when Hash
      pipeline_id = value['pipeline_id'] || value[:pipeline_id]
      stage_id    = value['stage_id'] || value[:stage_id]
      [pipeline_id, stage_id]
    when String, Symbol
      raw = value.to_s
      if raw.include?(':')
        pipeline_id, stage_id = raw.split(':', 2)
        [pipeline_id, stage_id]
      else
        [raw, nil]
      end
    else
      [nil, nil]
    end
  end

  def pipeline_item_already_in_pipeline?(pipeline_item, target_pipeline)
    pipeline_item.conversation_id.present? &&
      PipelineItem.where(conversation_id: pipeline_item.conversation_id, pipeline_id: target_pipeline.id)
                  .where.not(id: pipeline_item.id)
                  .exists?
  end

  # The frontend stores the Label UUID in action_value, but acts_as_taggable_on
  # compares against tags.name (the Label title). Translate UUIDs to titles
  # here so the rule lands the right tag instead of creating a garbage tag
  # named after the UUID.
  def resolve_label_title(value)
    Labels::TokenResolver.titles_for([value]).first || value.to_s
  end

  def build_outgoing_message(conversation, text, source)
    sender = conversation.inbox&.agent_bot
    ::Messages::MessageBuilder.new(
      nil, conversation,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: text,
      sender: sender,
      content_attributes: { automation_source: source }
    ).perform
  end

  def build_ai_payload(conversation, suggested_message)
    inbox = conversation.inbox
    {
      event: 'inactivity_action',
      id: SecureRandom.uuid,
      message_type: 'incoming',
      content: ai_prompt(suggested_message),
      conversation: conversation.webhook_data.merge(id: conversation.id),
      conversation_id: conversation.id,
      inbox: inbox.webhook_data,
      inbox_id: inbox.id,
      sender: conversation.contact.webhook_data,
      contact_id: conversation.contact.id,
      created_at: Time.current.to_i,
      inactivity_metadata: {
        action_type: 'interact',
        source: 'stage_inactivity',
        suggested_message: suggested_message,
        is_system_prompt: true
      }
    }
  end

  def ai_prompt(suggested_message)
    base = '<system_message>[SYSTEM - INACTIVITY ACTION] The customer has been inactive. ' \
           'Generate a proactive, natural message to re-engage them, relevant to the conversation context.'
    base += " Suggestion: #{suggested_message}" if suggested_message.present?
    base + '<important>Reply ONLY with the message text for the customer. Do NOT use tools. ' \
           'Do NOT add meta-commentary.</important></system_message>'
  end
end
