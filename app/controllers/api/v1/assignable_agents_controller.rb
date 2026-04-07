class Api::V1::AssignableAgentsController < Api::V1::BaseController
  before_action :fetch_inboxes

  def index
    agent_ids = @inboxes.map do |inbox|
      authorize inbox, :show?
      member_ids = inbox.members.pluck(:user_id)
      member_ids
    end
    agent_ids = agent_ids.inject(:&)
    agents = User.where(id: agent_ids)
    @assignable_agents = (agents + User.with_role(:administrator)).uniq
    
    success_response(
      data: UserSerializer.serialize_collection(@assignable_agents),
      message: 'Assignable agents retrieved successfully'
    )
  end

  private

  def fetch_inboxes
    @inboxes = Inbox.find(permitted_params[:inbox_ids])
  end

  def permitted_params
    params.permit(inbox_ids: [])
  end
end
