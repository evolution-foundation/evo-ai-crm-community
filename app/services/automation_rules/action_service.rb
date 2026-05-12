class AutomationRules::ActionService < ActionService
  def initialize(rule, _account = nil, conversation = nil)
    super(conversation)
    @rule = rule
    Current.executed_by = rule
  end

  def perform
    @rule.actions.each do |action|
      @conversation.reload
      action = action.with_indifferent_access
      begin
        Rails.logger.info "Automation Rule #{@rule.id}: Executing action #{action[:action_name]} with params #{action[:action_params]}"
        send(action[:action_name], action[:action_params])
      rescue StandardError => e
        Rails.logger.error "Automation Rule #{@rule.id}: Error executing action #{action[:action_name]}: #{e.message}"
        EvolutionExceptionTracker.new(e).capture_exception
      end
    end
  ensure
    Current.reset
  end

  private

  def send_attachment(attachment_params)
    return if conversation_a_tweet?

    # Suporte para formato antigo (array de IDs) e novo formato (hash com opções)
    if attachment_params.is_a?(Array)
      # Formato legado: apenas array de blob_ids
      blob_ids = attachment_params
      inbox_id = nil
    elsif attachment_params.is_a?(Hash)
      # Novo formato: hash com attachment_ids e inbox_id opcional
      blob_ids = attachment_params[:attachment_ids] || attachment_params['attachment_ids']
      inbox_id = attachment_params[:inbox_id] || attachment_params['inbox_id']
    else
      # Formato único: assumir que é um array de IDs
      blob_ids = [attachment_params].flatten
      inbox_id = nil
    end

    return unless @rule.files.attached?

    blobs = ActiveStorage::Blob.where(id: blob_ids)

    return if blobs.blank?

    # Preparar parâmetros da mensagem
    params = { content: nil, private: false, attachments: blobs }

    # Se um inbox específico foi fornecido, validar se a conversa pertence a esse inbox
    if inbox_id
      inbox = Inbox.find_by(id: inbox_id)
      if inbox && @conversation.inbox != inbox
        Rails.logger.warn "Automation Rule #{@rule.id}: Inbox mismatch. Conversation inbox: #{@conversation.inbox.id}, Requested inbox: #{inbox_id}"
        # Opcionalmente, pode escolher não enviar ou enviar pelo inbox da conversa
        # Por ora, vamos logar e continuar com o inbox da conversa
      end
    end

    Messages::MessageBuilder.new(nil, @conversation, params).perform
  rescue StandardError => e
    Rails.logger.error "Automation Rule #{@rule.id}: Error sending attachment: #{e.message}"
    raise e
  end

  def send_webhook_event(webhook_url)
    payload = @conversation.webhook_data.merge(event: "automation_event.#{@rule.event_name}")
    # Sanitize the webhook URL to remove any leading/trailing whitespace or tabs
    clean_url = webhook_url[0].to_s.strip
    WebhookJob.perform_later(clean_url, payload)
  end

  def send_message(message)
    return if conversation_a_tweet?

    params = { content: message[0], private: false, content_attributes: { automation_rule_id: @rule.id } }
    Messages::MessageBuilder.new(nil, @conversation, params).perform
  end

  def send_canned_response(params)
    return if conversation_a_tweet?
    return if params.blank?

    canned_id = params[0].is_a?(Hash) ? (params[0][:canned_response_id] || params[0]['canned_response_id']) : params[0]
    canned = CannedResponse.find_by(id: canned_id)
    return unless canned

    message_params = {
      content: canned.content,
      private: false,
      content_attributes: { automation_rule_id: @rule.id }
    }

    if canned.attachments.any?
      blobs = canned.attachments.map(&:file).select(&:attached?).map(&:blob)
      message_params[:attachments] = blobs if blobs.any?
    end

    Messages::MessageBuilder.new(nil, @conversation, message_params).perform
  end

  def send_template(params)
    return if conversation_a_tweet?
    return if params.blank?

    template_message = params[0].is_a?(Hash) ? params[0].deep_symbolize_keys : nil
    return unless template_message

    processed = Whatsapp::TemplateProcessingService.new(template_message).process
    return if processed.blank?

    message_params = {
      content: nil,
      private: false,
      message_type: :outgoing,
      content_type: 'template',
      content_attributes: { automation_rule_id: @rule.id }.merge(processed)
    }

    Messages::MessageBuilder.new(nil, @conversation, message_params).perform
  end

  def send_email_to_team(params)
    teams = Team.where(id: params[0][:team_ids])

    teams.each do |team|
      TeamNotifications::AutomationNotificationMailer.conversation_creation(@conversation, team, params[0][:message])&.deliver_now
    end
  end

  def assign_to_pipeline(pipeline_params)
    return unless pipeline_params[0]

    pipeline_id = extract_pipeline_id(pipeline_params[0])
    pipeline = Pipeline.find_by(id: pipeline_id)

    return unless pipeline

    log_pipeline_assignment(pipeline)
    execute_pipeline_assignment(pipeline)
  end

  def update_pipeline_stage(stage_params)
    return unless stage_params[0]

    stage = find_stage_by_params(stage_params[0])
    return unless stage

    log_stage_update_attempt(stage)
    @conversation.reload

    pipeline_item = @conversation.pipeline_items.find_by(pipeline: stage.pipeline)

    if pipeline_item
      move_to_existing_stage(pipeline_item, stage)
    else
      auto_assign_and_move_to_stage(stage)
    end
  end

  def extract_pipeline_id(param)
    param.is_a?(Hash) ? param[:id] : param
  end

  def log_pipeline_assignment(pipeline)
    Rails.logger.info "Automation Rule #{@rule.id}: Assigning conversation #{@conversation.id} to pipeline #{pipeline.name} (ID: #{pipeline.id})"
  end

  def execute_pipeline_assignment(pipeline)
    @conversation.pipeline_items.destroy_all
    result = Pipelines::ConversationService.new(pipeline: pipeline, user: nil).add_conversation(@conversation)

    if result
      log_assignment_success(pipeline)
    else
      log_assignment_failure(pipeline)
    end
  end

  def log_assignment_success(pipeline)
    Rails.logger.info "Automation Rule #{@rule.id}: Successfully assigned conversation #{@conversation.id} to pipeline #{pipeline.name}"
  end

  def log_assignment_failure(pipeline)
    Rails.logger.error "Automation Rule #{@rule.id}: Failed to assign conversation #{@conversation.id} to pipeline #{pipeline.name}"
  end

  def find_stage_by_params(param)
    stage_id = param.is_a?(Hash) ? param[:id] : param
    PipelineStage.find_by(id: stage_id)
  end

  def log_stage_update_attempt(stage)
    Rails.logger.info "Automation Rule #{@rule.id}: Attempting to move conversation #{@conversation.id} to stage #{stage.name} (ID: #{stage.id})"
  end

  def move_to_existing_stage(pipeline_item, stage)
    service = Pipelines::ConversationService.new(pipeline: stage.pipeline, user: nil)
    success = service.move_to_stage(pipeline_item, stage)

    if success
      log_stage_move_success(stage)
    else
      log_stage_move_failure(stage)
    end
  end

  def auto_assign_and_move_to_stage(stage)
    log_auto_assignment_attempt(stage)

    service = Pipelines::ConversationService.new(pipeline: stage.pipeline, user: nil)
    result = service.add_conversation(@conversation, stage: stage.pipeline.pipeline_stages.first)

    if result
      log_auto_assignment_success(stage)
      move_to_target_stage_after_assignment(stage, service)
    else
      log_auto_assignment_failure(stage)
    end
  end

  def log_auto_assignment_attempt(stage)
    Rails.logger.info "Automation Rule #{@rule.id}: Conversation #{@conversation.id} not in pipeline #{stage.pipeline.name}, auto-assigning first"
  end

  def log_auto_assignment_success(stage)
    Rails.logger.info "Automation Rule #{@rule.id}: Successfully auto-assigned conversation to pipeline #{stage.pipeline.name}"
  end

  def log_auto_assignment_failure(stage)
    Rails.logger.error "Automation Rule #{@rule.id}: Failed to auto-assign conversation #{@conversation.id} to pipeline #{stage.pipeline.name}"
  end

  def move_to_target_stage_after_assignment(stage, service)
    @conversation.reload
    pipeline_item = @conversation.pipeline_items.find_by(pipeline: stage.pipeline)

    return unless pipeline_item && stage != stage.pipeline.pipeline_stages.first

    service.move_to_stage(pipeline_item, stage)
    log_stage_move_success(stage)
  end

  def log_stage_move_success(stage)
    Rails.logger.info "Automation Rule #{@rule.id}: Successfully moved conversation #{@conversation.id} to stage #{stage.name}"
  end

  def log_stage_move_failure(stage)
    Rails.logger.error "Automation Rule #{@rule.id}: Failed to move conversation #{@conversation.id} to stage #{stage.name}"
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def create_pipeline_task(task_params)
    return unless @conversation.pipeline_items.exists?

    pipeline_item = @conversation.pipeline_items.first
    params = task_params[0] || {}

    # Extract task attributes
    title = params[:title]
    description = params[:description]
    task_type = params[:task_type]
    priority = params[:priority]
    assigned_to_id = params[:assigned_to_id]
    due_in = params[:due_in]

    task = pipeline_item.tasks.create!(
      created_by_id: User.where(type: 'SuperAdmin').first&.id,
      assigned_to_id: assigned_to_id,
      title: title,
      description: description,
      task_type: task_type,
      due_date: calculate_due_date(due_in),
      priority: priority
    )

    Rails.logger.info "Automation Rule #{@rule.id}: Created task #{task.id} for conversation #{@conversation.id}"
  rescue StandardError => e
    Rails.logger.error "Automation Rule #{@rule.id}: Error creating pipeline task: #{e.message}"
    EvolutionExceptionTracker.new(e).capture_exception
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def calculate_due_date(due_in)
    return nil if due_in.blank?

    # due_in can be: "1.hour", "24.hours", "2.days", etc.
    # or a direct timestamp
    return Time.zone.parse(due_in) if due_in.is_a?(String) && due_in.match?(/^\d{4}-\d{2}-\d{2}/)

    value, unit = due_in.to_s.split('.')
    return nil unless value.present? && unit.present?

    value.to_i.send(unit).from_now
  rescue StandardError => e
    Rails.logger.error "Error parsing due_date: #{e.message}"
    nil
  end
end

