class Api::V1::Conversations::AssignmentsController < Api::V1::Conversations::BaseController
  # assigns agent/team to a conversation
  def create
    if params.key?(:assignee_id)
      set_agent
    elsif params.key?(:team_id)
      set_team
    else
      error_response(
        ApiErrorCodes::MISSING_REQUIRED_FIELD,
        'Either assignee_id or team_id is required',
        status: :bad_request
      )
    end
  end

  private

  def set_agent
    @agent = User.find_by(id: params[:assignee_id])
    @conversation.assignee = @agent
    @conversation.save!
    
    if @agent.nil?
      success_response(
        data: {},
        message: 'Agent assignment removed successfully'
      )
    else
      success_response(
        data: { assignee: UserSerializer.serialize(@agent) },
        message: 'Agent assigned successfully'
      )
    end
  end

  def set_team
    @team = Team.find_by(id: params[:team_id])
    @conversation.update!(team: @team)
    
    success_response(
      data: { team: @team ? TeamSerializer.serialize(@team) : nil },
      message: 'Team assigned successfully'
    )
  end
end
