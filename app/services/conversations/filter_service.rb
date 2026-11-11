class Conversations::FilterService < FilterService
  ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def initialize(params, user, _account = nil)
    super(params, user)
  end

  def perform
    validate_query_operator
    @conversations = query_builder(@filters['conversations'])
    mine_count, unassigned_count, all_count, = set_count_for_all_conversations
    assigned_count = all_count - unassigned_count

    {
      conversations: conversations,
      count: {
        mine_count: mine_count,
        assigned_count: assigned_count,
        unassigned_count: unassigned_count,
        all_count: all_count
      }
    }
  end

  def base_relation
    conversations = Conversation
                            .joins(:contact)  # Filter out conversations without contacts
                            .joins(:inbox)    # JOIN inboxes for channel_type filtering
                            .preload(
                              :inbox,
                              :contact,
                              :assignee,
                              :team,
                              :contact_inbox,
                              :taggings,
                              pipeline_items: [:pipeline, :pipeline_stage, :stage_movements]
                            )
                            # NOTE: no `messages:` preload here on purpose. The controller renders
                            # this list with `include_messages: false` and gets the last-message
                            # preview from `last_non_activity_messages_map` (a self-contained LATERAL
                            # SQL query, independent of any association preload) — so eager-loading
                            # every message (+ attachments + file blobs) of every matched conversation
                            # was pure waste, and the dominant cost on conversations with long history.

    Conversations::PermissionFilterService.new(
      conversations,
      @user
    ).perform
  end

  def current_page
    @params[:page] || 1
  end

  def filter_config
    {
      entity: 'Conversation',
      table_name: 'conversations'
    }
  end

  def conversations
    # Honra sort_by igual ao index (ConversationFinder), em vez de hard-codar
    # last_activity_at DESC — elimina a divergência index vs filtro. Default
    # continua last_activity_at_desc (agora com tiebreaker estável via SortHandler).
    sort_method, sort_order =
      ConversationFinder::SORT_OPTIONS[@params[:sort_by]] ||
      ConversationFinder::SORT_OPTIONS['last_activity_at_desc']
    @conversations.send(sort_method, sort_order).page(current_page)
  end
end
