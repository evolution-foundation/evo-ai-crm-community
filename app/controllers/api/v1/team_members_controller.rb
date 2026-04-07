class Api::V1::TeamMembersController < Api::V1::BaseController
  require_permissions({
    index: 'team_members.read',
    show: 'team_members.read',
    create: 'team_members.create',
    update: 'team_members.update',
    destroy: 'team_members.delete'
  })
  before_action :fetch_team
  
  before_action :validate_member_id_params, only: [:create, :update, :destroy]

  def index
    @team_members = @team.team_members.map(&:user)
    
    success_response(
      data: TeamMemberSerializer.serialize_collection(@team_members),
      message: 'Team members retrieved successfully'
    )
  end

  def create
    ActiveRecord::Base.transaction do
      @team_members = @team.add_members(members_to_be_added_ids)
    end
    
    success_response(
      data: TeamMemberSerializer.serialize_collection(@team_members),
      message: 'Team members added successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  def update
    ActiveRecord::Base.transaction do
      @team.add_members(members_to_be_added_ids)
      @team.remove_members(members_to_be_removed_ids)
    end
    @team_members = @team.members
    
    success_response(
      data: TeamMemberSerializer.serialize_collection(@team_members),
      message: 'Team members updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  def destroy
    ActiveRecord::Base.transaction do
      @team.remove_members(params[:user_ids])
    end
    
    success_response(
      data: nil,
      message: 'Team members removed successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  private

  def members_to_be_added_ids
    params[:user_ids] - current_members_ids
  end

  def members_to_be_removed_ids
    current_members_ids - params[:user_ids]
  end

  def current_members_ids
    @current_members_ids ||= @team.members.pluck(:id)
  end

  def fetch_team
    @team = Team.find(params[:team_id])
  end

  def validate_member_id_params
    invalid_ids = params[:user_ids].map(&:to_i) - User.pluck(:id)

    render json: { error: 'Invalid User IDs' }, status: :unauthorized and return if invalid_ids.present?
  end
end
