class Api::V1::Agents::ApikeysController < Api::V1::BaseController
  require_permissions({
    index: 'agent_apikeys.read',
    show: 'agent_apikeys.read',
    create: 'agent_apikeys.create',
    update: 'agent_apikeys.update',
    destroy: 'agent_apikeys.delete'
  })
  
  
  def index
    result = EvoAiCoreService.list_api_keys(current_user, index_params)
    render json: result
  end
  
  def show
    result = EvoAiCoreService.get_api_key(current_user, params[:id])
    render json: result
  end
  
  def create
    result = EvoAiCoreService.create_api_key(current_user, api_key_params)
    render json: result, status: :created
  end
  
  def update
    result = EvoAiCoreService.update_api_key(current_user, params[:id], api_key_params)
    render json: result
  end
  
  def destroy
    EvoAiCoreService.delete_api_key(current_user, params[:id])
    head :no_content
  end
  
  private
  
  
  def index_params
    params.permit(:skip, :limit, :page, :pageSize)
  end
  
  def api_key_params
    params.permit(:name, :provider, :key, :key_value, :base_url, :value, :description)
  end
end
