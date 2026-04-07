class Api::V1::Agents::Folders::SharedController < Api::V1::BaseController
  require_permissions({
    index: 'agent_shared_folders.read',
    show: 'agent_shared_folders.read',
    create: 'agent_shared_folders.create',
    update: 'agent_shared_folders.update',
    destroy: 'agent_shared_folders.delete'
  })
  
  
  def update
    result = EvoAiCoreService.update_shared_folder(current_user, params[:id], share_params)
    render json: result
  end
  
  def destroy
    EvoAiCoreService.delete_shared_folder(current_user, params[:id])
    head :no_content
  end
  
  private
  
  
  def share_params
    params.permit(:permission_level)
  end
end