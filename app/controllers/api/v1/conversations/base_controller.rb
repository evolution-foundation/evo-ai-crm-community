class Api::V1::Conversations::BaseController < Api::V1::BaseController
  include ConversationResolver

  before_action :conversation

  private

  def conversation
    @conversation ||= resolve_conversation(params[:conversation_id])
    raise ActiveRecord::RecordNotFound if @conversation.nil?

    # 🔒 PROTEÇÃO: Autorizar apenas se inbox existir
    # Se inbox não existir, autorizar a conversa diretamente (conversas podem existir sem inbox/channel)
    if @conversation.inbox.present?
    authorize @conversation.inbox, :show?
    else
      authorize @conversation, :show?
    end
  end
end
