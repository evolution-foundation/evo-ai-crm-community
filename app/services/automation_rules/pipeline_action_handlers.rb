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
    # Units a `due_in` may be written in, mapped to the ActiveSupport duration method
    # they stand for. Two spellings of the same thing land here: the compact form the
    # automation screen advertises ("2d", "1w" — automation.json:create_pipeline_task_due_in
    # in all 7 locales) and the legacy dotted form rules were written with ("3.days").
    #
    # This is also the security boundary. `value.to_i.send(unit)` used to take whatever
    # string the rule's JSON carried, so a `due_in` of "1.destroy" reached `1.destroy` —
    # user-supplied config calling an arbitrary method on Integer. An unknown unit is now
    # a parse failure, never a method call.
    #
    # `m` alone is deliberately absent: it reads as "minutes" to one operator and
    # "months" to the next, and silently picking either schedules the other one's task
    # some 43_000x off. Both are reachable unambiguously as "30min"/"6mo" (or via the
    # dotted "30.minutes"/"6.months").
    DUE_IN_UNITS = {
      'min' => :minutes, 'minute' => :minutes, 'minutes' => :minutes,
      'h' => :hours, 'hour' => :hours, 'hours' => :hours,
      'd' => :days, 'day' => :days, 'days' => :days,
      'w' => :weeks, 'week' => :weeks, 'weeks' => :weeks,
      'mo' => :months, 'month' => :months, 'months' => :months,
      'y' => :years, 'year' => :years, 'years' => :years
    }.freeze

    # Matches "2d", "1w", "2 D" and the legacy "3.days" with one expression. The optional
    # sign preserves the dotted form's previous `to_i` behaviour ("-1.days" stayed in the
    # past); the optional dot and spaces make the compact form forgiving of what an
    # operator actually types.
    DUE_IN_PATTERN = /\A([+-]?\d+)\s*\.?\s*([a-z]+)\z/i

    # An absolute date ("2026-09-30", optionally with a time after it) is handed to
    # Time.zone.parse untouched.
    DUE_IN_ABSOLUTE_PATTERN = /\A\d{4}-\d{2}-\d{2}/

    private

    def assign_to_pipeline(pipeline_params)
      return unless pipeline_params[0]

      pipeline_id = extract_pipeline_id(pipeline_params[0])
      pipeline = Pipeline.find_by(id: pipeline_id)

      unless pipeline
        log_pipeline_not_found(pipeline_id)
        return
      end

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

      pipeline_item = @conversation.pipeline_items.active.find_by(pipeline: stage.pipeline)

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

      due_date = calculate_due_date(due_in)
      return if skip_unparseable_due_in(due_in, due_date)

      creator_id = pipeline_task_creator_id(pipeline_item)
      return if skip_without_task_creator(creator_id)

      task = pipeline_item.tasks.create!(
        created_by_id: creator_id,
        assigned_to_id: assigned_to_id,
        title: title,
        description: description,
        task_type: task_type,
        due_date: due_date,
        priority: priority
      )

      Rails.logger.info "Automation Rule #{@rule.id}: Created task #{task.id} for conversation #{@conversation.id}"
    rescue StandardError => e
      Rails.logger.error "Automation Rule #{@rule.id}: Error creating pipeline task: #{e.message}"
      EvolutionExceptionTracker.new(e).capture_exception
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # exists? reads without instantiating; a legacy STI-typed row raises on load, which is
    # also why the sibling resolve_task_creator's User.order(:created_at).first stays out.
    def pipeline_task_creator_id(pipeline_item)
      candidates = [pipeline_item.pipeline&.created_by_id,
                    @conversation&.assignee_id,
                    pipeline_item.assigned_by_id]

      candidates.compact.find { |id| User.exists?(id: id) }
    end

    # created_by_id is NOT NULL, so no author means no task. Without this the create!
    # raises into the rescue below and the operator sees nothing.
    def skip_without_task_creator(creator_id)
      return false if creator_id.present?

      Rails.logger.warn(
        "Automation Rule #{@rule.id}: no user can be recorded as the author of the task " \
        '(board owner, assignee and assigner are all missing or deleted); ' \
        "skipping create_pipeline_task for conversation #{@conversation.id}"
      )
      @recorder&.action_skipped!(
        'Skipped: create_pipeline_task',
        data: { reason: 'no_task_creator' }
      )
      true
    end

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
      # info, not action_skipped!: the conversation IS in the pipeline, so the run is not degraded.
      @recorder&.add_step(
        'assign_to_pipeline: already in the pipeline',
        data: { pipeline_id: pipeline.id, pipeline_name: pipeline.name }
      )
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
      pipeline_item = @conversation.pipeline_items.active.find_by(pipeline: stage.pipeline)

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

    # nil means "no due date" for a blank due_in and "could not read it" for anything
    # else — the caller tells the two apart via skip_unparseable_due_in, because only
    # the second one must stop the task from being created.
    def calculate_due_date(due_in)
      return nil if due_in.blank?

      raw = due_in.to_s.strip
      return Time.zone.parse(raw) if raw.match?(DUE_IN_ABSOLUTE_PATTERN)

      match = DUE_IN_PATTERN.match(raw)
      return nil unless match

      unit = DUE_IN_UNITS[match[2].downcase]
      return nil unless unit

      match[1].to_i.public_send(unit).from_now
    rescue StandardError => e
      Rails.logger.error "Error parsing due_date: #{e.message}"
      nil
    end

    # A due_in the parser cannot read must NOT become a task with no due date — that is
    # the failure the customer reported (CRM-563): the rule reports "Matched", the task
    # exists, and nothing ever comes due. Between refusing and creating-and-logging we
    # refuse, following the house pattern for an action that turns itself down mid-run
    # (skip_archived_pipeline): a warn in the Rails log AND a `Skipped:` step on the
    # rule's execution timeline, which also downgrades the run status — the operator
    # reads that timeline, not the server log. A dateless task would otherwise sit in
    # the board looking scheduled, which is worse than no task at all.
    def skip_unparseable_due_in(due_in, due_date)
      return false if due_in.blank? || due_date.present?

      Rails.logger.warn(
        "Automation Rule #{@rule.id}: due_in #{due_in.to_s.inspect} is not a date or a duration " \
        '(expected e.g. 2d, 1w, 3.days or 2026-09-30); ' \
        "skipping create_pipeline_task for conversation #{@conversation.id}"
      )
      @recorder&.action_skipped!(
        'Skipped: create_pipeline_task',
        data: { reason: 'invalid_due_in', due_in: due_in.to_s }
      )
      true
    end
  end
end
