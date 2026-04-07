class Api::V1::Conversations::DirectUploadsController < ActiveStorage::DirectUploadsController
  before_action :conversation

  def create
    return if @conversation.nil?

    super
  end

  private

  def conversation
    @conversation ||= Conversation.find_by(display_id: params[:conversation_id])
  end
end
