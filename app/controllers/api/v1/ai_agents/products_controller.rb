class Api::V1::AiAgents::ProductsController < Api::V1::BaseController
  require_permissions({
    index:   'products.read',
    create:  'ai_agents.update',
    destroy: 'ai_agents.update'
  })

  def index
    products = Product
               .joins(:ai_agent_products)
               .where(ai_agent_products: { ai_agent_id: ai_agent_id })

    success_response(
      data: ProductSerializer.serialize_collection(products),
      message: 'Agent products retrieved successfully'
    )
  end

  # POST /api/v1/ai_agents/:ai_agent_id/products
  # Body: { product_ids: [uuid] } or { product_id: uuid }
  def create
    ids = Array(params[:product_ids] || params[:product_id]).map(&:to_s).reject(&:blank?)
    if ids.empty?
      return error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Provide product_ids or product_id',
        status: :unprocessable_entity
      )
    end

    found_products = Product.where(id: ids).pluck(:id).map(&:to_s)
    missing        = ids - found_products
    if missing.any?
      return error_response(
        code: ApiErrorCodes::RESOURCE_NOT_FOUND,
        message: "Products not found: #{missing.join(', ')}",
        status: :not_found
      )
    end

    created = []
    found_products.each do |product_id|
      record = AiAgentProduct.where(ai_agent_id: ai_agent_id, product_id: product_id).first_or_create!
      created << record
    end

    sync_agent_config

    success_response(
      data: { ai_agent_id: ai_agent_id, attached: created.map(&:product_id) },
      message: 'Products attached to AI agent successfully',
      status: :created
    )
  end

  # DELETE /api/v1/ai_agents/:ai_agent_id/products/:id
  def destroy
    record = AiAgentProduct.find_by(ai_agent_id: ai_agent_id, product_id: params[:id])
    if record.nil?
      return error_response(
        code: ApiErrorCodes::RESOURCE_NOT_FOUND,
        message: 'Attachment not found',
        status: :not_found
      )
    end

    record.destroy!
    sync_agent_config

    success_response(
      data: { ai_agent_id: ai_agent_id, detached: params[:id] },
      message: 'Product detached from AI agent successfully'
    )
  end

  private

  def ai_agent_id
    params[:ai_agent_id]
  end

  def sync_agent_config
    Ai::AgentProductSyncService
      .new(ai_agent_id: ai_agent_id, request_headers: request.headers)
      .call
  end
end
