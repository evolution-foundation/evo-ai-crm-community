class Api::V1::Contacts::ConversationsController < Api::V1::Contacts::BaseController
  include ConversationListLookups

  # Same key the main conversation list requires: reaching the list through a
  # contact must not read more than reading it directly.
  require_permissions({ index: 'conversations.read' })

  CONVERSATIONS_PER_PAGE = 20

  def index
    page = contact_conversations_page
    @conversations = page.to_a
    conversation_ids = @conversations.map(&:id)

    success_response(
      data: ConversationSerializer.serialize_collection(
        @conversations,
        include_labels: true,
        unread_counts: unread_counts_map(conversation_ids),
        last_non_activity_messages: last_non_activity_messages_map(conversation_ids),
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      meta: conversation_page_meta(page),
      message: 'Contact conversations retrieved successfully'
    )
  end

  private

  def contact_conversations_page
    # Start with all conversations for this contact
    conversations = Conversation.preload(
      { inbox: [:channel, :agent_bot_inbox] }, :assignee, :contact, :team,
      { pipeline_items: [:pipeline, :pipeline_stage] }
    ).where(contact_id: @contact.id)

    # Apply permission-based filtering using the existing service
    conversations = Conversations::PermissionFilterService.new(
      conversations,
      Current.user,
      nil
    ).perform

    # `id` breaks ties: last_activity_at repeats across an import, and an
    # unstable order drops or repeats rows between pages.
    conversations.order(last_activity_at: :desc, id: :desc)
                 .page(current_page)
                 .per(CONVERSATIONS_PER_PAGE)
  end

  def current_page
    requested = params[:page].to_i
    requested.positive? ? requested : 1
  end
end
