class Api::V1::ProceduresController < Api::V1::BaseController
  include FileTypeHelper

  skip_before_action :authenticate_request!, only: [:public_show]

  require_permissions({
    index: 'procedures.read',
    show: 'procedures.read',
    create: 'procedures.create',
    update: 'procedures.update',
    destroy: 'procedures.delete',
    publish: 'procedures.publish',
    archive: 'procedures.update',
    send_to_conversation: 'procedures.send_to_customer'
  })

  before_action :fetch_procedure, only: [:show, :update, :destroy, :publish, :archive, :send_to_conversation]

  MAX_ATTACHMENT_BYTES = 40.megabytes
  UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.freeze
  ARRAY_PAYLOAD_FIELDS = %w[tags content_blocks visibility targets].freeze
  HASH_PAYLOAD_FIELDS = %w[metadata].freeze
  BLOCK_TYPES = %w[heading paragraph checklist image video file link button].freeze

  def index
    @procedures = procedures_scope
                  .includes(:procedure_visibilities, :procedure_targets, attachments: { file_attachment: :blob })
                  .search(params[:search])
                  .order(updated_at: :desc)

    apply_pagination

    paginated_response(
      data: ProcedureSerializer.serialize_collection(@procedures, include_public_token: can_share_public_link?),
      collection: @procedures,
      message: 'Procedures retrieved successfully'
    )
  end

  def show
    success_response(
      data: ProcedureSerializer.serialize(@procedure, include_public_token: can_share_public_link?),
      message: 'Procedure retrieved successfully'
    )
  end

  def public_show
    procedure = Procedure
                .published
                .includes(:procedure_visibilities, attachments: { file_attachment: :blob })
                .find_by(public_token: params[:token])

    unless procedure&.procedure_visibilities&.any? { |visibility| visibility.scope_type == 'public_link' }
      return error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Procedure not found', status: :not_found)
    end

    success_response(
      data: ProcedureSerializer.serialize(procedure),
      message: 'Procedure retrieved successfully'
    )
  end

  def create
    return if reject_invalid_procedure_payload
    return if reject_visibility_permission(force: true)
    return if reject_public_share_permission
    return if reject_oversized_attachments
    return if reject_invalid_signed_ids

    @procedure = Procedure.new(procedure_attributes.merge(created_by_id: current_user&.id, updated_by_id: current_user&.id))

    ActiveRecord::Base.transaction do
      @procedure.save!
      replace_visibility!
      replace_targets!
      attach_files if params[:attachments].present?
    end

    success_response(
      data: ProcedureSerializer.serialize(@procedure.reload, include_public_token: can_share_public_link?),
      message: 'Procedure created successfully',
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    validation_error(e.record)
  end

  def update
    return if reject_invalid_procedure_payload
    return if reject_visibility_permission
    return if reject_public_share_permission
    return if reject_oversized_attachments
    return if reject_invalid_signed_ids

    ActiveRecord::Base.transaction do
      @procedure.update!(procedure_attributes.merge(updated_by_id: current_user&.id))
      replace_visibility! if procedure_payload.key?('visibility')
      replace_targets! if procedure_payload.key?('targets')
      detach_files if params[:remove_attachment_ids].present?
      attach_files if params[:attachments].present?
    end

    success_response(
      data: ProcedureSerializer.serialize(@procedure.reload, include_public_token: can_share_public_link?),
      message: 'Procedure updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    validation_error(e.record)
  end

  def destroy
    @procedure.archive!
    success_response(
      data: { id: @procedure.id },
      message: 'Procedure archived successfully'
    )
  end

  def publish
    if @procedure.archived?
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Archived procedures cannot be published',
        status: :unprocessable_entity
      )
    end
    return if public_link_visibility? && reject_missing_share_permission

    @procedure.publish!
    ensure_public_token! if public_link_visibility?
    success_response(
      data: ProcedureSerializer.serialize(@procedure.reload, include_public_token: can_share_public_link?),
      message: 'Procedure published successfully'
    )
  end

  def archive
    @procedure.archive!
    success_response(
      data: ProcedureSerializer.serialize(@procedure.reload, include_public_token: can_share_public_link?),
      message: 'Procedure archived successfully'
    )
  end

  def send_to_conversation
    unless @procedure.published?
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Procedure must be published before it can be sent to customers',
        status: :unprocessable_entity
      )
    end

    unless @procedure.customer_shareable?
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Procedure is internal only and cannot be sent to customers',
        status: :unprocessable_entity
      )
    end

    conversation = accessible_conversation_scope.find_by(id: params[:conversation_id])
    return error_response(ApiErrorCodes::CONVERSATION_NOT_FOUND, 'Conversation not found', status: :not_found) unless conversation

    return if public_link_visibility? && reject_missing_share_permission

    ensure_public_token! if public_link_visibility?
    success_response(
      data: {
        procedure_id: @procedure.id,
        conversation_id: conversation.id,
        share_url: @procedure.public_token.present? ? "/procedures/public/#{@procedure.public_token}" : nil,
        content_blocks: @procedure.content_blocks
      },
      message: 'Procedure share payload generated successfully'
    )
  end

  private

  def fetch_procedure
    @procedure = action_name.in?(%w[show send_to_conversation]) ? procedures_scope.find_by(id: params[:id]) : Procedure.find_by(id: params[:id])
    return if @procedure

    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Procedure not found', status: :not_found)
  end

  def procedures_scope
    Procedure.active.visible_to(current_user, management: management_scope?)
  end

  def management_scope?
    Current.service_authenticated == true ||
      current_user&.administrator? ||
      can_perform_action?('procedures', 'update') ||
      can_perform_action?('procedures', 'manage_visibility')
  end

  def procedure_payload
    @procedure_payload ||= begin
      raw_payload = params[:procedure] || {}
      raw_payload.respond_to?(:to_unsafe_h) ? raw_payload.to_unsafe_h : raw_payload.to_h
    end
  end

  def procedure_attributes
    payload = procedure_payload
    attributes = payload.slice('title', 'description', 'category', 'usage_mode')
    attributes['tags'] = normalize_json_array(payload['tags']) if payload.key?('tags')
    attributes['content_blocks'] = normalize_json_array(payload['content_blocks']) if payload.key?('content_blocks')
    attributes['metadata'] = normalize_json_hash(payload['metadata']) if payload.key?('metadata')
    attributes.compact
  end

  def replace_visibility!
    scopes = normalize_json_array(procedure_payload['visibility'])
    scopes = [{ 'scope_type' => 'all', 'scope_id' => nil }] if scopes.blank?

    @procedure.procedure_visibilities.destroy_all
    scopes.each do |scope|
      @procedure.procedure_visibilities.create!(
        scope_type: scope['scope_type'] || scope[:scope_type],
        scope_id: scope['scope_id'] || scope[:scope_id]
      )
    end
    public_link_visibility? ? ensure_public_token! : clear_public_token!
  end

  def replace_targets!
    targets = normalize_json_array(procedure_payload['targets'])
    @procedure.procedure_targets.destroy_all
    targets.each do |target|
      @procedure.procedure_targets.create!(
        target_type: target['target_type'] || target[:target_type],
        target_id: target['target_id'] || target[:target_id]
      )
    end
  end

  def public_link_visibility?
    @procedure.procedure_visibilities.any? { |visibility| visibility.scope_type == 'public_link' }
  end

  def ensure_public_token!
    return if @procedure.public_token.present?

    @procedure.update!(public_token: SecureRandom.urlsafe_base64(24))
  end

  def clear_public_token!
    return if @procedure.public_token.blank?

    @procedure.update!(public_token: nil)
  end

  def reject_visibility_permission(force: false)
    return false unless force || procedure_payload.key?('visibility')
    return false if can_manage_visibility?

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'You do not have permission to manage procedure visibility',
      status: :forbidden
    )
    true
  end

  def reject_public_share_permission
    return false unless procedure_payload.key?('visibility')
    return false unless normalized_visibility_payload.any? { |visibility| value_for(visibility, 'scope_type') == 'public_link' }

    reject_missing_share_permission
  end

  def reject_missing_share_permission
    return false if can_share_public_link?

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'You do not have permission to share procedures through public links',
      status: :forbidden
    )
    true
  end

  def can_manage_visibility?
    Current.service_authenticated == true ||
      current_user&.administrator? ||
      can_perform_action?('procedures', 'manage_visibility')
  end

  def can_share_public_link?
    Current.service_authenticated == true ||
      current_user&.administrator? ||
      can_perform_action?('procedures', 'share')
  end

  def accessible_conversation_scope
    return Conversation.all if Current.service_authenticated == true || current_user&.administrator? || Current.evo_can_read_all_inboxes

    Conversation.where(inbox: current_user&.assigned_inboxes)
  end

  def reject_invalid_procedure_payload
    return true if invalid_json_payload?
    return true if invalid_usage_mode?
    return true if invalid_visibility_payload?
    return true if invalid_targets_payload?
    return true if invalid_content_blocks_payload?

    false
  end

  def invalid_json_payload?
    ARRAY_PAYLOAD_FIELDS.each do |field|
      value = procedure_payload[field]
      next if value.blank? || value.is_a?(Array) || value.is_a?(ActionController::Parameters)

      parsed = JSON.parse(value.to_s)
      next if parsed.is_a?(Array)

      return invalid_payload("#{field} must be an array")
    rescue JSON::ParserError
      return invalid_payload("#{field} must be valid JSON")
    end

    HASH_PAYLOAD_FIELDS.each do |field|
      value = procedure_payload[field]
      next if value.blank? || value.is_a?(Hash) || value.is_a?(ActionController::Parameters)

      parsed = JSON.parse(value.to_s)
      next if parsed.is_a?(Hash)

      return invalid_payload("#{field} must be an object")
    rescue JSON::ParserError
      return invalid_payload("#{field} must be valid JSON")
    end

    false
  end

  def invalid_usage_mode?
    usage_mode = procedure_payload['usage_mode']
    return false if usage_mode.blank? || Procedure.usage_modes.key?(usage_mode)

    invalid_payload('usage_mode is invalid')
  end

  def invalid_visibility_payload?
    normalized_visibility_payload.each do |visibility|
      scope_type = value_for(visibility, 'scope_type')
      scope_id = value_for(visibility, 'scope_id')
      next unless scope_type.in?(%w[team inbox])
      next if valid_uuid?(scope_id)

      return invalid_payload('visibility scope_id must be a valid UUID for team and inbox scopes')
    end

    false
  end

  def invalid_targets_payload?
    normalize_json_array(procedure_payload['targets']).each do |target|
      target_id = value_for(target, 'target_id')
      next if valid_uuid?(target_id)

      return invalid_payload('target_id must be a valid UUID')
    end

    false
  end

  def invalid_content_blocks_payload?
    normalize_json_array(procedure_payload['content_blocks']).each do |block|
      block_id = value_for(block, 'id')
      block_type = value_for(block, 'type')
      next if block_id.present? && BLOCK_TYPES.include?(block_type)

      return invalid_payload('content_blocks must include id and a valid type')
    end

    false
  end

  def normalized_visibility_payload
    normalize_json_array(procedure_payload['visibility'])
  end

  def value_for(payload, key)
    return nil unless payload.respond_to?(:[])

    payload[key] || payload[key.to_sym]
  rescue TypeError
    nil
  end

  def valid_uuid?(value)
    value.to_s.match?(UUID_REGEX)
  end

  def invalid_payload(message)
    error_response(ApiErrorCodes::VALIDATION_ERROR, message, status: :unprocessable_entity)
    true
  end

  def normalize_json_array(value)
    return [] if value.blank?
    return value.values if value.is_a?(ActionController::Parameters)
    return value if value.is_a?(Array)

    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  def normalize_json_hash(value)
    return {} if value.blank?
    return value.to_unsafe_h if value.is_a?(ActionController::Parameters)
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def attach_files
    normalized_attachments.each do |attachment_param|
      if attachment_param.is_a?(ActionController::Parameters) || attachment_param.is_a?(Hash)
        if attachment_param[:signed_id].present?
          attach_from_signed_id(attachment_param[:signed_id])
        elsif attachment_param[:file].present?
          attach_from_file(attachment_param[:file])
        end
      elsif attachment_param.respond_to?(:read)
        attach_from_file(attachment_param)
      end
    end
  end

  def normalized_attachments
    if params[:attachments].is_a?(Array)
      params[:attachments]
    elsif params[:attachments].is_a?(ActionController::Parameters)
      params[:attachments].values
    else
      [params[:attachments]].compact
    end
  end

  def reject_oversized_attachments
    return false if params[:attachments].blank?
    return false unless normalized_attachments.any? { |attachment| attachment_byte_size(attachment).to_i > MAX_ATTACHMENT_BYTES }

    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      "Attachment exceeds the maximum allowed size (#{MAX_ATTACHMENT_BYTES / 1.megabyte} MB)",
      status: :unprocessable_entity
    )
    true
  end

  def reject_invalid_signed_ids
    return false if params[:attachments].blank?

    invalid = normalized_attachments.any? do |attachment_param|
      next false unless attachment_param.is_a?(ActionController::Parameters) || attachment_param.is_a?(Hash)
      next false if attachment_param[:signed_id].blank?

      ActiveStorage::Blob.find_signed(attachment_param[:signed_id]).nil?
    end
    return false unless invalid

    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'One or more attachments reference an invalid or expired upload',
      status: :unprocessable_entity
    )
    true
  end

  def attachment_byte_size(attachment_param)
    if attachment_param.is_a?(ActionController::Parameters) || attachment_param.is_a?(Hash)
      if attachment_param[:signed_id].present?
        ActiveStorage::Blob.find_signed(attachment_param[:signed_id])&.byte_size
      elsif attachment_param[:file].respond_to?(:size)
        attachment_param[:file].size
      end
    elsif attachment_param.respond_to?(:size)
      attachment_param.size
    end
  end

  def attach_from_file(file)
    attachment = @procedure.attachments.build(
      file_type: determine_file_type(file.content_type),
      fallback_title: file.original_filename
    )
    attachment.file.attach(io: file, filename: file.original_filename, content_type: file.content_type)
    attachment.save!
  end

  def attach_from_signed_id(signed_id)
    blob = ActiveStorage::Blob.find_signed(signed_id)
    attachment = @procedure.attachments.build(
      file_type: file_type_by_signed_id(signed_id),
      fallback_title: blob&.filename&.to_s
    )
    attachment.file.attach(blob)
    attachment.save!
  end

  def determine_file_type(content_type)
    return :image if image_file?(content_type)
    return :video if video_file?(content_type)
    return :audio if content_type&.include?('audio/')

    :file
  end

  def detach_files
    ids = Array(params[:remove_attachment_ids]).reject(&:blank?)
    return if ids.empty?

    @procedure.attachments.where(id: ids).destroy_all
    @procedure.attachments.reload
  end

  def validation_error(record)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: record.errors.full_messages,
      status: :unprocessable_entity
    )
  end
end
