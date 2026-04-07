# frozen_string_literal: true

class Api::V1::AiFoldersController < Api::V1::BaseController

  def index
    params_hash = {
      page: params[:page] || 1,
      pageSize: params[:pageSize] || 100
    }

    Rails.logger.info "AI Folders Index - User: #{Current.user&.id}, Params: #{params_hash}"
    
    response = EvoAiCoreService.list_folders(params_hash, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folders retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    Rails.logger.error "AI Folders Index Error: #{e.message}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def show
    response = EvoAiCoreService.get_folder(params[:id])
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folder retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def create
    response = EvoAiCoreService.create_folder(folder_create_params)

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folder created successfully'
    success_response(data: data, message: message, status: :created)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update
    response = EvoAiCoreService.update_folder(params[:id], folder_update_params)

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folder updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def destroy
    response = EvoAiCoreService.delete_folder(params[:id])

    message = response.is_a?(Hash) ? response['message'] : 'Folder deleted successfully'
    success_response(message: message, status: :no_content)  
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def agents
    response = EvoAiCoreService.list_folder_agents(params[:id])
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folder agents retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def share
    share_data = {
      permissions: params[:permissions],
      user_ids: params[:user_ids]
    }.compact
    
    response = EvoAiCoreService.share_folder(params[:id], share_data)

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folder shared successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def shared
    response = EvoAiCoreService.get_shared_folder(params[:id])
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Shared folder retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def shared_folders
    response = EvoAiCoreService.list_shared_folders
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Shared folders retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def accessible_folders
    response = EvoAiCoreService.list_accessible_folders

    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Accessible folders retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update_shared
    share_data = {
      permissions: params[:permissions],
      user_ids: params[:user_ids]
    }.compact
    
    response = EvoAiCoreService.update_shared_folder(params[:id], share_data)
    
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Shared folder updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def delete_shared
    response = EvoAiCoreService.delete_shared_folder(params[:id])

    message = response.is_a?(Hash) ? response['message'] : 'Shared folder deleted successfully'
    success_response(message: message, status: :no_content)  
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def permitted_params
    params.permit(:name, :description, :color, :icon, :permissions, user_ids: [])
  end

  def folder_create_params
    {
      name: permitted_params[:name],
      description: permitted_params[:description],
      color: permitted_params[:color],
      icon: permitted_params[:icon]
    }.compact
  end

  def folder_update_params
    {
      name: permitted_params[:name],
      description: permitted_params[:description],
      color: permitted_params[:color],
      icon: permitted_params[:icon]
    }.compact
  end
end