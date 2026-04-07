class Api::V1::Agents::FoldersController < Api::V1::BaseController
  require_permissions({
    index: 'agent_folders.read',
    show: 'agent_folders.read',
    create: 'agent_folders.create',
    update: 'agent_folders.update',
    destroy: 'agent_folders.delete'
  })
  
  
  def index
    # Rota GET /agents/folders não existe no core, usar list
    result = EvoAiCoreService.list_folders(current_user, index_params)
    render json: result
  end
  
  def list
    result = EvoAiCoreService.list_folders(current_user, index_params)
    render json: result
  end
  
  def show
    result = EvoAiCoreService.get_folder(current_user, params[:id])
    render json: result
  end
  
  def create
    result = EvoAiCoreService.create_folder(current_user, folder_params)
    render json: result, status: :created
  end
  
  def update
    result = EvoAiCoreService.update_folder(current_user, params[:id], folder_params)
    render json: result
  end
  
  def destroy
    EvoAiCoreService.delete_folder(current_user, params[:id])
    head :no_content
  end
  
  def agents
    result = EvoAiCoreService.list_folder_agents(current_user, params[:id])
    render json: result
  end
  
  def share
    result = EvoAiCoreService.share_folder(current_user, params[:id], share_params)
    render json: result
  end
  
  def shared
    result = EvoAiCoreService.get_shared_folder(current_user, params[:id])
    render json: result
  end
  
  def shared_folders
    result = EvoAiCoreService.list_shared_folders(current_user)
    render json: result
  end
  
  def accessible
    result = EvoAiCoreService.list_accessible_folders(current_user)
    render json: result
  end
  
  private
  
  
  def index_params
    params.permit(:page, :pageSize, :skip, :limit)
  end
  
  def folder_params
    params.permit(:name, :description, :color, :icon)
  end
  
  def share_params
    params.permit(:email, :permission_level)
  end
end