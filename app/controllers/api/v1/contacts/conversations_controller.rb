class Api::V1::Contacts::ConversationsController < Api::V1::Contacts::BaseController
  include ConversationListPreloads

  def index
    # Start with all conversations for this contact
    conversations = Conversation.preload(
      { inbox: :agent_bot_inbox }, :assignee, :contact, :team,
      { pipeline_items: [:pipeline, :pipeline_stage] }
    ).where(contact_id: @contact.id)

    # Apply permission-based filtering using the existing service
    conversations = Conversations::PermissionFilterService.new(
      conversations,
      Current.user,
      nil
    ).perform

    @conversations = conversations.order(last_activity_at: :desc).limit(20).to_a
    conversation_ids = @conversations.map(&:id)

    success_response(
      data: ConversationSerializer.serialize_collection(
        @conversations,
        unread_counts: unread_counts_map(conversation_ids),
        last_non_activity_messages: last_non_activity_messages_map(conversation_ids)
      ),
      message: 'Contact conversations retrieved successfully'
    )
  end
end
