# frozen_string_literal: true

class Api::V1::AiAgentsController < Api::V1::BaseController

  def index
    params_hash = {
      skip: params[:skip] || 0,
      limit: params[:limit] || 100
    }
    params_hash[:folder_id] = params[:folder_id] if params[:folder_id].present?

    Rails.logger.info "AI Agents Index - User: #{Current.user&.id}, Params: #{params_hash}"
    Rails.logger.info "AI Agents Index - Request Headers: #{request.headers.env.select { |k,v| k.to_s.match?(/token|auth|uid|client/i) }.keys}"
    
    response = EvoAiCoreService.list_agents(params_hash, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Agents retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    Rails.logger.error "AI Agents Index Error: #{e.message}"
    Rails.logger.error "AI Agents Index Backtrace: #{e.backtrace.first(10).join("\n")}"
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def show
    response = EvoAiCoreService.get_agent(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Agent retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def create
    response = EvoAiCoreService.create_agent(agent_create_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Agent created successfully'
    success_response(data: data, message: message, status: :created)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def update
    response = EvoAiCoreService.update_agent(params[:id], agent_update_params, request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Agent updated successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def destroy
    EvoAiCoreService.delete_agent(params[:id], request.headers)
    head :no_content
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def sync_evolution
    response = EvoAiCoreService.sync_evolution_bot(params[:id], request.headers)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Evolution bot synced successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def assign_folder
    folder_id = params[:folder_id]
    response = EvoAiCoreService.assign_folder(params[:id], folder_id)
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Folder assigned successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def share
    response = EvoAiCoreService.get_share_agent(params[:id])
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Share agent retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  def shared
    response = EvoAiCoreService.get_shared_agent(params[:id])
    
    data = response.is_a?(Hash) ? (response['data'] || response) : response
    message = response.is_a?(Hash) ? response['message'] : 'Shared agent retrieved successfully'
    success_response(data: data, message: message)
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :unprocessable_entity)
  end

  private

  def permitted_params
    params.require(:agent).permit(:name, :type, :description, :model, :api_key_id, :instruction, 
                                   :folder_id, :role, :goal, :agent_card_url,
                                   config: {})
  end

  def agent_create_params
    agent_params = permitted_params
    result = {
      name: agent_params[:name],
      type: agent_params[:type],
      description: agent_params[:description],
      model: agent_params[:model],
      api_key_id: agent_params[:api_key_id],
      instruction: agent_params[:instruction],
      folder_id: agent_params[:folder_id],
      role: agent_params[:role],
      goal: agent_params[:goal],
      agent_card_url: agent_params[:agent_card_url]
    }.compact
    
    # Add config if present
    result[:config] = agent_params[:config] if agent_params[:config].present?
    
    result
  end

  def agent_update_params
    agent_params = permitted_params
    result = {
      name: agent_params[:name],
      description: agent_params[:description],
      type: agent_params[:type],
      model: agent_params[:model],
      api_key_id: agent_params[:api_key_id],
      instruction: agent_params[:instruction],
      folder_id: agent_params[:folder_id],
      role: agent_params[:role],
      goal: agent_params[:goal],
      agent_card_url: agent_params[:agent_card_url]
    }.compact
    
    # Add config if present
    result[:config] = agent_params[:config] if agent_params[:config].present?
    
    result
  end
end