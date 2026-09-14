class Api::V1::AgentsController < Api::V1::BaseController
  # This controller proxies AI-agent CRUD to evo-core (EvoAiCoreService), so its
  # gate is `ai_agents.*` — the same resource the frontend already gates the AI
  # screen with. The dead twin `agents.*` was consolidated away (EVO-2072).
  require_permissions({
    index: 'ai_agents.read',
    create: 'ai_agents.create',
    bulk_create: 'ai_agents.create',
    import: 'ai_agents.import',
    update: 'ai_agents.update',
    destroy: 'ai_agents.delete'
  })

  # Shared by the single and the batch path so the two cannot drift apart.
  AGENT_ATTRIBUTES = [
    :name, :description, :type, :model, :api_key_id, :instruction,
    :card_url, :folder_id, :role, :goal, { config: {} }
  ].freeze

  # The core caps nothing on the single-create path this fans out to.
  BULK_CREATE_LIMIT = 50

  # Declared here so they win over Api::BaseController's `rescue_from StandardError`.
  rescue_from EvoAiCoreService::UnavailableError, with: :handle_core_unavailable
  rescue_from EvoAiCoreService::UpstreamError, with: :handle_core_upstream_error

  def index
    result = EvoAiCoreService.list_agents(index_params, request.headers)
    render json: result
  end

  def create
    result = EvoAiCoreService.create_agent(agent_params, request.headers)
    render json: result, status: :created
  end

  # One core call per entry — the core has no JSON batch route — so the batch is
  # not atomic and the response has to say what was written.
  def bulk_create
    entries = bulk_create_entries
    return if performed?

    created = []

    entries.each_with_index do |agent_data, index|
      created << EvoAiCoreService.create_agent(agent_data, request.headers)
    rescue EvoAiCoreService::UnavailableError, EvoAiCoreService::UpstreamError => e
      raise e if index.zero?

      return render_partial_batch(created, index, e)
    end

    render json: { agents: created, created_count: created.size }, status: :created
  end

  def import
    if params[:file].blank?
      return error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        'file is required',
        status: :bad_request
      )
    end

    result = EvoAiCoreService.import_agents(params[:file], params[:folder_id], request.headers)
    render json: result, status: :created
  end

  def update
    result = EvoAiCoreService.update_agent(params[:id], agent_params, request.headers)
    render json: result
  end

  def destroy
    EvoAiCoreService.delete_agent(params[:id], request.headers)
    head :no_content
  end
  
  private

  def handle_core_unavailable(exception)
    log_core_failure(exception)
    error_response(
      ApiErrorCodes::SERVICE_UNAVAILABLE,
      'AI core service is unavailable',
      status: :service_unavailable
    )
  end

  # 4xx is relayed; 5xx (and 401, a CRM<->core credential problem, not the
  # client's) becomes 502. The core's wording is logged, never echoed.
  def handle_core_upstream_error(exception)
    log_core_failure(exception)

    status = exception.status.to_i
    if status.between?(400, 499) && status != 401
      error_response(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
        'AI core service rejected the request',
        details: { upstream_status: status },
        status: status
      )
    else
      error_response(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
        'AI core service failed to process the request',
        details: { upstream_status: status },
        status: :bad_gateway
      )
    end
  end

  def log_core_failure(exception)
    Rails.logger.error(
      "[agents proxy] #{exception.class}: #{exception.message} " \
      "(#{request.method} #{request.original_fullpath})"
    )
  end

  def index_params
    params.permit(:skip, :limit, :folder_id, :page, :pageSize)
  end
  
  def agent_params
    params.permit(*AGENT_ATTRIBUTES)
  end

  def render_partial_batch(created, index, exception)
    log_core_failure(exception)

    render json: {
      agents: created,
      created_count: created.size,
      failed_at: index,
      error: {
        code: ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
        message: 'AI core service stopped accepting the batch'
      }
    }, status: :multi_status
  end

  # Renders the rejection itself; callers check `performed?` before going on.
  def bulk_create_entries
    entries = params[:agents]

    unless batch_of_objects?(entries)
      return reject_batch(ApiErrorCodes::MISSING_REQUIRED_FIELD,
                          'agents must be a non-empty array of agent objects')
    end

    if entries.size > BULK_CREATE_LIMIT
      return reject_batch(ApiErrorCodes::INVALID_INPUT,
                          "agents accepts at most #{BULK_CREATE_LIMIT} items per request",
                          details: { limit: BULK_CREATE_LIMIT, received: entries.size },
                          status: :unprocessable_entity)
    end

    params.permit(agents: AGENT_ATTRIBUTES)[:agents]
  end

  def batch_of_objects?(entries)
    entries.is_a?(Array) && entries.present? &&
      entries.all? { |entry| entry.is_a?(ActionController::Parameters) || entry.is_a?(Hash) }
  end

  def reject_batch(code, message, details: nil, status: :bad_request)
    error_response(code, message, details: details, status: status)
    []
  end
end