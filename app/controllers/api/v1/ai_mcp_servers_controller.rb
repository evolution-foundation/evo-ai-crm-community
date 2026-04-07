# frozen_string_literal: true

class Api::V1::AiMcpServersController < Api::V1::BaseController

  def index
    params_hash = {
      skip: params[:skip] || 0,
      limit: params[:limit] || 100
    }

    Rails.logger.info "AI MCP Servers Index - User: #{Current.user&.id}, Params: #{params_hash}"
    
    response = EvoAiCoreService.list_mcp_servers(params_hash, request.headers)

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'MCP servers retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    Rails.logger.error "AI MCP Servers Index Error: #{e.message}"
    Rails.logger.error "AI MCP Servers Index Backtrace: #{e.backtrace.first(10).join("\n")}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def show
    response = EvoAiCoreService.get_mcp_server(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'MCP server retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def create
    response = EvoAiCoreService.create_mcp_server(mcp_server_create_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'MCP server created successfully'
    success_response(data: data, message: message, status: :created)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update
    response = EvoAiCoreService.update_mcp_server(params[:id], mcp_server_update_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'MCP server updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def destroy
    response = EvoAiCoreService.delete_mcp_server(params[:id], request.headers)
    
    message = response.is_a?(Hash) ? response['message'] : 'MCP server deleted successfully'
    success_response(message: message, status: :no_content)  
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def permitted_params
    params.permit(:name, :description, :url, :version, :capabilities, :auth_config, :metadata)
  end

  def mcp_server_create_params
    {
      name: permitted_params[:name],
      description: permitted_params[:description],
      url: permitted_params[:url],
      version: permitted_params[:version],
      capabilities: permitted_params[:capabilities],
      auth_config: permitted_params[:auth_config],
      metadata: permitted_params[:metadata]
    }.compact
  end

  def mcp_server_update_params
    mcp_server_create_params
  end
end