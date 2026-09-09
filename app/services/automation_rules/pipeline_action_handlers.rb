module AutomationRules
  # Shared pipeline action handlers consumed by both the modal-style
  # AutomationRules::ActionService and the flow-canvas-style
  # AutomationRules::FlowExecutionService. Single source of truth for the
  # three pipeline actions and the create_pipeline_task action so both
  # executor surfaces stay in lockstep — see app/services/automation_rules/README.md.
  #
  # Required instance state on the including class:
  #   @rule         — AutomationRule (logging + rubocop:disable signature parity)
  #   @conversation — Conversation (target of pipeline mutations)
  #
  # All methods are private when included, mirroring ActionService's original
  # surface. Public callers should drive `perform` (ActionService) or
  # `execute_node_action` (FlowExecutionService); they invoke these via send/
  # direct private dispatch.
  module PipelineActionHandlers
    private

    def assign_to_pipeline(pipeline_params)
      return unless pipeline_params[0]

      pipeline_id = extract_pipeline_id(pipeline_params[0])
      pipeline = Pipeline.find_by(id: pipeline_id)

      unless pipeline
        log_pipeline_not_found(pipeline_id)
        return
      end

      # An archived pipeline is hidden from every picker, so a rule written months ago must not
      # keep pushing conversations into it. (Until CRM-566 this guard carried a second job:
      # execute_pipeline_assignment opened with a destroy_all, so reaching it also wiped every
      # OTHER pipeline membership of the conversation. That wipe is gone — see the comment there.)
      return if skip_archived_pipeline(pipeline, action: 'assign_to_pipeline')

      log_pipeline_assignment(pipeline)
      execute_pipeline_assignment(pipeline)
    end

    def update_pipeline_stage(stage_params)
      return unless stage_params[0]

      stage = find_stage_by_params(stage_params[0])
      return unless stage
      return if skip_archived_pipeline(stage.pipeline, action: 'update_pipeline_stage')

      log_stage_update_attempt(stage)
      @conversation.reload

      pipeline_item = @conversation.pipeline_items.find_by(pipeline: stage.pipeline)

      if pipeline_item
        move_to_existing_stage(pipeline_item, stage)
      else
        auto_assign_and_move_to_stage(stage)
      end
    end

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def create_pipeline_task(task_params)
      return unless @conversation.pipeline_items.exists?

      pipeline_item = @conversation.pipeline_items.first
      params = task_params[0] || {}

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
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    def extract_pipeline_id(param)
      param.is_a?(Hash) ? param[:id] : param
    end

    def log_pipeline_assignment(pipeline)
      Rails.logger.info "Automation Rule #{@rule.id}: Assigning conversation #{@conversation.id} to pipeline #{pipeline.name} (ID: #{pipeline.id})"
    end

    # An archived pipeline is hidden from every picker, so a rule written months ago must
    # not keep dragging conversations into it. The reason goes to the Rails log AND to the
    # rule's execution timeline via action_skipped!, which also downgrades the run status:
    # the timeline records every action as success before it runs, so a bare step would be
    # contradicted by a green "Matched" result (EVO-2202).
    def skip_archived_pipeline(pipeline, action:)
      return false if pipeline.nil? || pipeline.is_active

      Rails.logger.warn(
        "Automation Rule #{@rule.id}: Pipeline #{pipeline.id} is archived; " \
        "skipping #{action} for conversation #{@conversation.id}"
      )
      @recorder&.action_skipped!(
        "Skipped: #{action}",
        data: { reason: 'pipeline_archived', pipeline_id: pipeline.id, pipeline_name: pipeline.name }
      )
      true
    end

    def log_pipeline_not_found(pipeline_id)
      Rails.logger.warn "Automation Rule #{@rule.id}: Pipeline #{pipeline_id.inspect} not found; skipping assign_to_pipeline for conversation #{@conversation.id}"
    end

    # CRM-566: this used to open with `@conversation.pipeline_items.destroy_all`, so assigning
    # a conversation to funnel B hard-deleted its card in funnel A — taking stage_movements,
    # PipelineTasks and pipeline_item_products with it (all `dependent: :destroy`). The wipe
    # contradicted the very schema it leaned on: `idx_pipeline_items_active_conversation_per_pipeline`
    # is unique on (conversation_id, pipeline_id), not on conversation_id, precisely BECAUSE a
    # conversation may live in several funnels at once. Only "twice in the SAME funnel" is
    # forbidden, and the unique index plus PipelineItem's uniqueness validation already forbid it.
    #
    # So the only thing this action has to avoid is a second ACTIVE item in the target pipeline,
    # which is now a no-op instead of a delete-and-recreate. A COMPLETED item in the target
    # pipeline is deliberately not treated as "already there": the index is partial on
    # `completed_at IS NULL`, so a closed journey is history and a fresh assignment is a new
    # active card next to it.
    def execute_pipeline_assignment(pipeline)
      @conversation.reload

      existing_item = @conversation.pipeline_items.active.find_by(pipeline_id: pipeline.id)
      return log_assignment_noop(pipeline) if existing_item

      result = Pipelines::ConversationService.new(pipeline: pipeline, user: nil).add_conversation(@conversation)

      if result
        log_assignment_success(pipeline)
      else
        log_assignment_failure(pipeline)
      end
    end

    def log_assignment_noop(pipeline)
      Rails.logger.info "Automation Rule #{@rule.id}: Conversation #{@conversation.id} is already active in " \
                        "pipeline #{pipeline.name}; assign_to_pipeline is a no-op"
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

    def calculate_due_date(due_in)
      return nil if due_in.blank?

      return Time.zone.parse(due_in) if due_in.is_a?(String) && due_in.match?(/^\d{4}-\d{2}-\d{2}/)

      value, unit = due_in.to_s.split('.')
      return nil unless value.present? && unit.present?

      value.to_i.send(unit).from_now
    rescue StandardError => e
      Rails.logger.error "Error parsing due_date: #{e.message}"
      nil
    end
  end
end
