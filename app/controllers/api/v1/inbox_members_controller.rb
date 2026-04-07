class Api::V1::InboxMembersController < Api::V1::BaseController
  before_action :fetch_inbox
  before_action :current_agents_ids, only: [:create, :update]

  def show
    authorize @inbox, :show?
    fetch_updated_agents
    
    success_response(
      data: UserSerializer.serialize_collection(@agents),
      message: 'Inbox members retrieved successfully'
    )
  end

  def create
    authorize @inbox, :create?
    ActiveRecord::Base.transaction do
      @inbox.add_members(agents_to_be_added_ids)
    end
    fetch_updated_agents
    
    success_response(
      data: UserSerializer.serialize_collection(@agents),
      message: 'Inbox members added successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  def update
    authorize @inbox, :update?
    update_agents_list
    fetch_updated_agents
    
    success_response(
      data: UserSerializer.serialize_collection(@agents),
      message: 'Inbox members updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  def destroy
    authorize @inbox, :destroy?
    ActiveRecord::Base.transaction do
      @inbox.remove_members(params[:user_ids])
    end
    
    success_response(
      data: nil,
      message: 'Inbox members removed successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      code: ApiErrorCodes::VALIDATION_ERROR,
      message: e.message
    )
  end

  private

  def fetch_updated_agents
    @agents = User.where(id: @inbox.members.select(:user_id))
  end

  def update_agents_list
    # get all the user_ids which the inbox currently has as members.
    # get the list of  user_ids from params
    # the missing ones are the agents which are to be deleted from the inbox
    # the new ones are the agents which are to be added to the inbox
    ActiveRecord::Base.transaction do
      @inbox.add_members(agents_to_be_added_ids)
      @inbox.remove_members(agents_to_be_removed_ids)
    end
  end

  def agents_to_be_added_ids
    params[:user_ids] - @current_agents_ids
  end

  def agents_to_be_removed_ids
    @current_agents_ids - params[:user_ids]
  end

  def current_agents_ids
    @current_agents_ids = @inbox.members.pluck(:id)
  end

  def fetch_inbox
    @inbox = Inbox.find(params[:inbox_id])
  end
end
