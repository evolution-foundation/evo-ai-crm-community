class Api::V1::MacrosController < Api::V1::BaseController
  # Use-vs-manage split (CRM-70): reading and executing are attendance and stay
  # on read/execute; creating and editing are Settings-screen management and
  # demand macros.manage (admin roles only) — except on a personal macro, which
  # its owner keeps editing and deleting (see check_update_permission! below).
  require_permissions({
    index: 'macros.read',
    show: 'macros.read',
    create: 'macros.manage',
    execute: 'macros.execute'
  })

  # `update` and `destroy` are not in require_permissions because their check
  # depends on the record, so it has to run after fetch_macro. They still answer to
  # the conventional check_<action>_permission! hook (see below), which is what the
  # mutating-actions gate guard and the permission-key conformance registry look for.
  EvoPermissionConcern.register_permission_key('macros.delete')

  before_action :fetch_macro, only: [:show, :update, :destroy, :execute]
  before_action :check_update_permission!, only: [:update]
  before_action :check_destroy_permission!, only: [:destroy]

  def index
    @macros = Macro.with_visibility(current_user, params).with_attached_files
    
    apply_pagination
    
    paginated_response(
      data: MacroSerializer.serialize_collection(@macros),
      collection: @macros,
      message: 'Macros retrieved successfully'
    )
  end

  def show
    success_response(
      data: MacroSerializer.serialize(@macro),
      message: 'Macro retrieved successfully'
    )
  end

  def create
    macro_params = macros_with_user.except(:visibility).merge(created_by_id: current_user.id)
    @macro = Macro.new(macro_params)
    @macro.set_visibility(current_user, permitted_params)
    @macro.actions = params[:actions]

    unless @macro.valid?
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @macro.errors.full_messages,
        status: :unprocessable_entity
      )
    end
    return attachment_not_found unless attachments_usable?(@macro.actions)

    ActiveRecord::Base.transaction do
      @macro.save!
      process_attachments
    end

    success_response(
      data: MacroSerializer.serialize(@macro),
      message: 'Macro created successfully',
      status: :created
    )
  end

  def update
    actions_sent = params.key?(:actions)
    return attachment_not_found if actions_sent && !attachments_usable?(params[:actions])

    ActiveRecord::Base.transaction do
      # Actions come from params as in create: the array-only permit drops hash-shaped action_params.
      @macro.actions = params[:actions] if actions_sent
      update_params = macros_with_user.except(:visibility, :actions)
      @macro.update!(update_params)
      @macro.set_visibility(current_user, permitted_params)
      process_attachments if actions_sent
      @macro.save!
      
      success_response(
        data: MacroSerializer.serialize(@macro),
        message: 'Macro updated successfully'
      )
    rescue StandardError => e
      Rails.logger.error e
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Update failed',
        details: @macro.errors.full_messages,
        status: :unprocessable_entity
      )
      # Rescued inside the block, so without this the half-applied update commits.
      raise ActiveRecord::Rollback
    end
  end

  def destroy
    @macro.destroy
    success_response(
      data: { id: @macro.id },
      message: 'Macro deleted successfully'
    )
  end

  def execute
    result = ::MacrosExecutionJob.perform_now(@macro, conversation_ids: params[:conversation_ids], user: Current.user)

    execution_results = Array(result.executions).compact.map do |exec|
      {
        id: exec.id,
        conversation_id: exec.conversation_id,
        status: exec.status,
        error_message: exec.error_message,
        actions_result: exec.actions_result
      }
    end

    # An empty list and ids that do not exist are two different client errors; they
    # used to share one green 200.
    return missing_conversation_ids if result.requested_ids.empty?
    return conversations_not_found if execution_results.empty?

    # A count, not the ids: echoing which ids failed to resolve makes this an existence
    # oracle over `display_id`, a globally unique sequential integer.
    success_response(
      data: {
        macro_id: @macro.id,
        conversation_ids: result.requested_ids,
        executions: execution_results,
        unresolved_conversation_count: result.unresolved_ids.size
      },
      message: result.unresolved_ids.any? ? 'Macro execution completed for part of the conversations' : 'Macro execution completed'
    )
  end

  private

  # Keeps macro.files in step with the send_attachment actions: a replaced or
  # removed file is detached, so execution never sends a stale one.
  def process_attachments
    blob_ids = attachment_blob_ids(@macro.actions).compact_blank
    @macro.files_attachments.where.not(blob_id: blob_ids).destroy_all

    attached_ids = @macro.files_attachments.pluck(:blob_id)
    ActiveStorage::Blob.where(id: blob_ids - attached_ids).find_each { |blob| @macro.files.attach(blob) }
  end

  # Same two shapes Macros::ExecutionService#send_attachment reads. An action with
  # no id yields a blank one, so it is refused instead of saved empty.
  def attachment_blob_ids(actions)
    Array(actions).flat_map do |action|
      next [] unless action['action_name'] == 'send_attachment'

      action_params = action['action_params']
      ids = action_params.respond_to?(:key?) ? action_params['attachment_ids'] : action_params
      ids = Array(ids).map { |id| id.to_s.downcase }
      ids.presence || ['']
    end
  end

  # Usable means just uploaded (attached nowhere) or already this macro's: a bare
  # uuid must not pull in a file attached to someone else's record.
  def attachments_usable?(actions)
    blob_ids = attachment_blob_ids(actions).uniq
    return true if blob_ids.empty?
    return false if blob_ids.any?(&:blank?)

    usable = ActiveStorage::Blob.where(id: blob_ids).where.missing(:attachments).pluck(:id)
    usable += @macro.files_attachments.where(blob_id: blob_ids).pluck(:blob_id) if @macro.persisted?
    (blob_ids - usable).empty?
  end

  def permitted_params
    params.permit(
      :name, :visibility,
      actions: [:action_name, { action_params: [] }]
    )
  end

  def macros_with_user
    permitted_params.merge(updated_by_id: current_user.id)
  end

  def fetch_macro
    # CRM-195: scope the direct-by-id lookup by the same rule as the list, so another
    # user's PERSONAL macro answers 404 instead of leaking through 200/403. The 404
    # halts the before_action chain — see check_destroy_permission! for what that
    # ordering costs and why it is worth it.
    @macro = Macro.with_visibility(current_user, params).find_by(id: params[:id])
    macro_not_found if @macro.nil?
  end

  # Same carve-out as destroy, and for the same reason: a personal macro is its
  # owner's, not a shared asset, so editing it does not demand macros.manage
  # (CRM-70 moved create/update to that admin-only key). Without it the owner could
  # run and delete its own macro but never fix a typo in it.
  #
  # Like destroy, this runs after CRM-195's scoped fetch, so @macro is always in the
  # caller's scope by now: the decision here is only "own personal -> skip the key"
  # vs "global -> require macros.manage". Another user's personal macro never gets
  # this far (404), and an unknown id answers 404 too.
  def check_update_permission!
    return if own_personal_macro?

    check_permission!('macros.manage', :user)
  end

  # CRM-190 carve-out: Macro#set_visibility forces `personal` for every non-admin, so a
  # macro an agent creates is its own, not a shared asset — without this it could create
  # personal macros nobody, not even an admin, is able to remove.
  #
  # CRM-195 moved fetch_macro's scoped 404 AHEAD of this gate, so @macro is always in the
  # caller's scope by now: this only decides "own personal -> skip the key" vs "global ->
  # require macros.delete". Deliberate divergence from labels/canned_responses/
  # message_templates, which still gate before the fetch: hiding "user X has a personal
  # macro at this UUID" outranks a uniform 403. What that leaves open on GLOBAL ids is
  # pinned by macros_visibility_scope_rbac_spec.
  def check_destroy_permission!
    return if own_personal_macro?

    check_permission!('macros.delete', :user)
  end

  def own_personal_macro?
    @macro&.personal? && @macro.created_by_id.present? && @macro.created_by_id == Current.user&.id
  end

  def macro_not_found
    error_response(
      ApiErrorCodes::MACRO_NOT_FOUND,
      "Macro with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def attachment_not_found
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'send_attachment: the attached file was not found, upload it again',
      status: :unprocessable_entity
    )
  end

  def missing_conversation_ids
    error_response(
      ApiErrorCodes::MISSING_REQUIRED_FIELD,
      'conversation_ids is required and must list at least one conversation',
      status: :unprocessable_entity
    )
  end

  def conversations_not_found
    error_response(
      ApiErrorCodes::CONVERSATION_NOT_FOUND,
      'No conversation was found for the given conversation_ids',
      status: :not_found
    )
  end

end
