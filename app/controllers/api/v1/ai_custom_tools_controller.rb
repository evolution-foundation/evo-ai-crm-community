# frozen_string_literal: true

class Api::V1::AiCustomToolsController < Api::V1::BaseController
  require_permissions({
    index: 'ai_custom_tools.read',
    show: 'ai_custom_tools.read',
    create: 'ai_custom_tools.create',
    update: 'ai_custom_tools.update',
    destroy: 'ai_custom_tools.delete',
    test: 'ai_custom_tools.read'
  })

  def index
    params_hash = {
      skip: params[:skip] || 0,
      limit: params[:limit] || 100
    }
    params_hash[:search] = params[:search] if params[:search].present?
    params_hash[:tags] = params[:tags] if params[:tags].present?

    Rails.logger.info "AI Custom Tools Index - User: #{Current.user&.id}, Params: #{params_hash}"

    response = EvoAiCoreService.list_custom_tools(params_hash, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom tools retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    Rails.logger.error "AI Custom Tools Index Error: #{e.message}"
    Rails.logger.error "AI Custom Tools Index Backtrace: #{e.backtrace.first(10).join("\n")}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def show
    response = EvoAiCoreService.get_custom_tool(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom tool retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def create
    Rails.logger.info "AI Custom Tools Create - Raw Params: #{params.inspect}"
    create_params = custom_tool_create_params
    Rails.logger.info "AI Custom Tools Create - Processed Params: #{create_params.inspect}"

    response = EvoAiCoreService.create_custom_tool(create_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom tool created successfully'
    success_response(data: data, message: message, status: :created)
  rescue StandardError => e
    Rails.logger.error "AI Custom Tools Create Error: #{e.message}"
    Rails.logger.error "AI Custom Tools Create Backtrace: #{e.backtrace.first(10).join("\n")}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update
    response = EvoAiCoreService.update_custom_tool(params[:id], custom_tool_update_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom tool updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def destroy
    response = EvoAiCoreService.delete_custom_tool(params[:id], request.headers)
    
    message = response.is_a?(Hash) ? response['message'] : 'Custom tool deleted successfully'
    success_response(message: message, status: :no_content)  
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def test
    response = EvoAiCoreService.test_custom_tool(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom tool tested successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def permitted_params
    # Try nested params first, fallback to direct params for backward compatibility
    if params[:ai_custom_tool].present?
      params.require(:ai_custom_tool).permit(:name, :description, :endpoint, :method,
                                           tags: [], values: {}, examples: [],
                                           input_modes: [], output_modes: [], error_handling: {},
                                           headers: {}, body_params: {}, query_params: {}, path_params: {})
    else
      params.permit(:name, :description, :endpoint, :method, :tags, :values, :examples,
                    :input_modes, :output_modes, :error_handling,
                    headers: {}, body_params: {}, query_params: {}, path_params: {})
    end
  end

  def custom_tool_create_params
    tool_params = permitted_params
    {
      name: tool_params[:name],
      description: tool_params[:description],
      endpoint: tool_params[:endpoint],
      method: tool_params[:method],
      headers: tool_params[:headers] || {},
      body_params: tool_params[:body_params] || {},
      query_params: tool_params[:query_params] || {},
      path_params: tool_params[:path_params] || {},
      tags: tool_params[:tags] || [],
      values: tool_params[:values] || {},
      examples: tool_params[:examples] || [],
      input_modes: tool_params[:input_modes] || [],
      output_modes: tool_params[:output_modes] || [],
      error_handling: tool_params[:error_handling] || {}
    }.compact
  end

  def custom_tool_update_params
    custom_tool_create_params
  end
end
