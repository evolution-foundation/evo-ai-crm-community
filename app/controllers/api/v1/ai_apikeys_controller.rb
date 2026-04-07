# frozen_string_literal: true

class Api::V1::AiApikeysController < Api::V1::BaseController

  def index
    params_hash = {
      skip: params[:skip] || 0,
      limit: params[:limit] || 100
    }

    Rails.logger.info "AI API Keys Index - User: #{Current.user&.id}, Params: #{params_hash}"
    
    response = EvoAiCoreService.list_api_keys(params_hash, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'API keys retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    Rails.logger.error "AI API Keys Index Error: #{e.message}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def show
    response = EvoAiCoreService.get_api_key(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'API key retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def create
    response = EvoAiCoreService.create_api_key(api_key_create_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'API key created successfully'
    success_response(data: data, message: message, status: :created)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update
    response = EvoAiCoreService.update_api_key(params[:id], api_key_update_params, request.headers)

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'API key updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def destroy
    response = EvoAiCoreService.delete_api_key(params[:id], request.headers)
    message = response.is_a?(Hash) ? response['message'] : 'API key deleted successfully'
    success_response(message: message, status: :no_content)  
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def permitted_params
    params.permit(:name, :provider, :key_value, :value, :description, :is_active, :client_id)
  end

  def api_key_create_params
    {
      name: permitted_params[:name],
      provider: permitted_params[:provider],
      key_value: permitted_params[:key_value] || permitted_params[:value],
      description: permitted_params[:description]
    }.compact
  end

  def api_key_update_params
    {
      name: permitted_params[:name],
      provider: permitted_params[:provider],
      key_value: permitted_params[:key_value] || permitted_params[:value],
      description: permitted_params[:description],
      is_active: permitted_params[:is_active]
    }.compact
  end
end