# frozen_string_literal: true

class Api::V1::AiCustomMcpServersController < Api::V1::BaseController
  require_permissions({
    index: 'ai_custom_mcp_servers.read',
    show: 'ai_custom_mcp_servers.read',
    create: 'ai_custom_mcp_servers.create',
    update: 'ai_custom_mcp_servers.update',
    destroy: 'ai_custom_mcp_servers.delete',
    test: 'ai_custom_mcp_servers.read'
  })

  def index
    params_hash = {
      skip: params[:skip] || 0,
      limit: params[:limit] || 100
    }
    params_hash[:search] = params[:search] if params[:search].present?
    params_hash[:tags] = params[:tags] if params[:tags].present?

    Rails.logger.info "AI Custom MCP Servers Index - User: #{Current.user&.id}, Params: #{params_hash}"

    response = EvoAiCoreService.list_custom_mcp_servers(params_hash, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom MCP servers retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    Rails.logger.error "AI Custom MCP Servers Index Error: #{e.message}"
    Rails.logger.error "AI Custom MCP Servers Index Backtrace: #{e.backtrace.first(10).join("\n")}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def show
    response = EvoAiCoreService.get_custom_mcp_server(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom MCP server retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def create
    Rails.logger.info "AI Custom MCP Servers Create - Raw Params: #{params.inspect}"
    create_params = custom_mcp_server_create_params
    Rails.logger.info "AI Custom MCP Servers Create - Processed Params: #{create_params.inspect}"

    response = EvoAiCoreService.create_custom_mcp_server(create_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom MCP server created successfully'
    success_response(data: data, message: message, status: :created)
  rescue StandardError => e
    Rails.logger.error "AI Custom MCP Servers Create Error: #{e.message}"
    Rails.logger.error "AI Custom MCP Servers Create Backtrace: #{e.backtrace.first(10).join("\n")}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update
    response = EvoAiCoreService.update_custom_mcp_server(params[:id], custom_mcp_server_update_params, request.headers)

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom MCP server updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def destroy
    response = EvoAiCoreService.delete_custom_mcp_server(params[:id], request.headers)
    
    message = response.is_a?(Hash) ? response['message'] : 'Custom MCP server deleted successfully'
    success_response(message: message, status: :no_content)  
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def test
    response = EvoAiCoreService.test_custom_mcp_server(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Custom MCP server tested successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def permitted_params
    params.permit(:name, :description, :url, :timeout, :retry_count, tags: [], headers: {})
  end

  def custom_mcp_server_create_params
    {
      name: permitted_params[:name],
      description: permitted_params[:description],
      url: permitted_params[:url],
      timeout: permitted_params[:timeout],
      retry_count: permitted_params[:retry_count],
      tags: permitted_params[:tags] || [],
      headers: permitted_params[:headers] || {}
    }.compact
  end

  def custom_mcp_server_update_params
    custom_mcp_server_create_params
  end
end
