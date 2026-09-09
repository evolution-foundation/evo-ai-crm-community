class Api::V1::AgentsController < Api::V1::BaseController
  # This controller proxies AI-agent CRUD to evo-core (EvoAiCoreService), so its
  # gate is `ai_agents.*` — the same resource the frontend already gates the AI
  # screen with. The dead twin `agents.*` was consolidated away (EVO-2072).
  require_permissions({
    index: 'ai_agents.read',
    create: 'ai_agents.create',
    bulk_create: 'ai_agents.create',
    update: 'ai_agents.update',
    destroy: 'ai_agents.delete'
  })

  # CRM-565 — every action here is a proxy hop to evo-core, and a proxy answering
  # 500 says "the CRM broke", which is a lie when the core refused the request or
  # was not running. Both handlers are declared in this controller on purpose:
  # Api::BaseController's `rescue_from StandardError` (the one that produced the
  # reported 500) is matched last, so these take precedence over it.
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

  def update
    result = EvoAiCoreService.update_agent(params[:id], agent_params, request.headers)
    render json: result
  end

  def destroy
    EvoAiCoreService.delete_agent(params[:id], request.headers)
    head :no_content
  end
  
  private

  # The core was never reached (down, unreachable, or EVO_AI_CORE_SERVICE_URL not
  # pointing anywhere usable). 503 is the honest answer: nothing is wrong with the
  # request, and retrying later may work.
  def handle_core_unavailable(exception)
    log_core_failure(exception)
    error_response(
      ApiErrorCodes::SERVICE_UNAVAILABLE,
      'AI core service is unavailable',
      status: :service_unavailable
    )
  end

  # The core answered, but not 2xx. A 4xx is about the request the client made, so
  # it is relayed as-is. A 5xx is the core failing, which is a bad gateway from
  # here — relaying it verbatim would put the blame back on the CRM.
  # The core's own wording is deliberately NOT echoed: it can carry internal hosts,
  # SQL, or stack detail. It is logged instead; the client gets the status.
  def handle_core_upstream_error(exception)
    log_core_failure(exception)

    status = exception.status.to_i
    if status.between?(400, 499)
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
    params.permit(
      :name, 
      :description, 
      :type, 
      :model, 
      :api_key_id, 
      :instruction, 
      :card_url, 
      :folder_id, 
      :role,
      :goal,
      config: {}
    )
  end
end