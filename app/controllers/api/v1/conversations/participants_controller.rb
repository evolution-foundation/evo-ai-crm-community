class Api::V1::Conversations::ParticipantsController < Api::V1::Conversations::BaseController
  def show
    @participants = @conversation.conversation_participants.includes(:user)
    
    success_response(
      data: serialize_participants(@participants),
      message: 'Participants retrieved successfully'
    )
  end

  def create
    ActiveRecord::Base.transaction do
      @participants = participants_to_be_added_ids.map { |user_id| @conversation.conversation_participants.find_or_create_by(user_id: user_id) }
    end
    
    success_response(
      data: serialize_participants(@participants.reload.includes(:user)),
      message: 'Participants added successfully',
      status: :created
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to add participants',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def update
    ActiveRecord::Base.transaction do
      participants_to_be_added_ids.each { |user_id| @conversation.conversation_participants.find_or_create_by(user_id: user_id) }
      participants_to_be_removed_ids.each { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    @participants = @conversation.conversation_participants.includes(:user).reload
    
    success_response(
      data: serialize_participants(@participants),
      message: 'Participants updated successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to update participants',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def destroy
    ActiveRecord::Base.transaction do
      params[:user_ids].map { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    
    success_response(
      data: { removed_user_ids: params[:user_ids] },
      message: 'Participants removed successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to remove participants',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  private

  def serialize_participants(participants)
    participants.map do |participant|
      {
        id: participant.id,
        user_id: participant.user_id,
        conversation_id: participant.conversation_id,
        user: participant.user ? UserSerializer.serialize(participant.user) : nil,
        created_at: participant.created_at.to_i
      }
    end
  end

  def participants_to_be_added_ids
    params[:user_ids] - current_participant_ids
  end

  def participants_to_be_removed_ids
    current_participant_ids - params[:user_ids]
  end

  def current_participant_ids
    @current_participant_ids ||= @conversation.conversation_participants.pluck(:user_id)
  end
end
