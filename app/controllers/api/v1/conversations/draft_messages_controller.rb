class Api::V1::Conversations::DraftMessagesController < Api::V1::Conversations::BaseController
  def show
    unless Redis::Alfred.exists?(draft_redis_key)
      return success_response(
        data: { has_draft: false, message: nil },
        message: 'No draft message found'
      )
    end

    draft_message = Redis::Alfred.get(draft_redis_key)
    success_response(
      data: { has_draft: true, message: draft_message },
      message: 'Draft message retrieved successfully'
    )
  end

  def update
    Redis::Alfred.set(draft_redis_key, draft_message_params)
    success_response(
      data: { has_draft: true, message: draft_message_params },
      message: 'Draft message saved successfully'
    )
  end

  def destroy
    Redis::Alfred.delete(draft_redis_key)
    success_response(
      data: { has_draft: false, message: nil },
      message: 'Draft message deleted successfully'
    )
  end

  private

  def draft_redis_key
    format(Redis::Alfred::CONVERSATION_DRAFT_MESSAGE, id: @conversation.id)
  end

  def draft_message_params
    params.dig(:draft_message, :message) || ''
  end
end
