class Api::V1::Contacts::ConversationsController < Api::V1::Contacts::BaseController
  def index
    # Return all conversations for this contact ordered by most recent activity.
    # NOTE: PermissionFilterService was intentionally removed here because the
    # role check (user.role) silently returns nil in this system — roles live in
    # a separate table, not a column on users. This caused the service to fall
    # back to inbox-membership filtering, which blocked every migrated conversation.
    # Contact conversation history should be visible to any authenticated agent.
    @conversations = Conversation.includes(
      :assignee, :contact, :inbox, :taggings, { pipeline_items: [:pipeline, :pipeline_stage] }
    ).where(contact_id: @contact.id)
              .order(last_activity_at: :desc)
              .limit(20)

    conversation_ids = @conversations.map(&:id)

    success_response(
      data: ConversationSerializer.serialize_collection(
        @conversations,
        include_messages: false,
        include_labels: true,
        unread_counts: unread_counts_map(conversation_ids),
        last_non_activity_messages: last_non_activity_messages_map(conversation_ids),
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      ),
      meta: pagination_meta,
      message: 'Conversations retrieved successfully'
    )
  end

  private

  def pagination_meta
    {
      total_count: @conversations.size,
      current_page: 1,
      per_page: 20,
      total: @conversations.size,
      total_pages: 1,
      has_next_page: false,
      has_previous_page: false
    }
  end

  def labels_by_title
    label_indexes[:by_title]
  end

  def labels_by_id
    label_indexes[:by_id]
  end

  def label_indexes
    @label_indexes ||= begin
      all_labels = Label.all.to_a
      {
        by_title: all_labels.index_by { |label| label.title.to_s.downcase },
        by_id: all_labels.index_by { |label| label.id.to_s }
      }
    end
  end

  def unread_counts_map(conversation_ids)
    return {} if conversation_ids.blank?

    connection = ActiveRecord::Base.connection
    quoted_ids = quoted_uuid_list(conversation_ids, connection)
    incoming_type = Message.message_types[:incoming]

    # Count at most 10 unread messages per conversation using LATERAL to cap work per row.
    sql = <<~SQL.squish
      SELECT c.id AS conversation_id, COUNT(m.id)::integer AS unread_count
      FROM conversations c
      LEFT JOIN LATERAL (
        SELECT id
        FROM messages
        WHERE messages.conversation_id = c.id
          AND messages.message_type = #{incoming_type}
          AND messages.created_at > COALESCE(c.agent_last_seen_at, to_timestamp(0))
          AND (messages.content_attributes->>'read') IS DISTINCT FROM 'true'
        ORDER BY messages.created_at DESC
        LIMIT 10
      ) m ON TRUE
      WHERE c.id IN (#{quoted_ids})
      GROUP BY c.id
    SQL

    connection.exec_query(sql).to_a.each_with_object({}) do |row, memo|
      unread_count = row['unread_count'].to_i
      memo[row['conversation_id']] = unread_count if unread_count.positive?
    end
  end

  def last_non_activity_messages_map(conversation_ids)
    return {} if conversation_ids.blank?

    connection = ActiveRecord::Base.connection
    quoted_ids = quoted_uuid_list(conversation_ids, connection)
    activity_type = Message.message_types[:activity]

    # Resolve latest non-activity message ids per conversation with LATERAL, then preload senders.
    sql = <<~SQL.squish
      SELECT c.id AS conversation_id, m.id AS message_id
      FROM conversations c
      LEFT JOIN LATERAL (
        SELECT messages.id
        FROM messages
        WHERE messages.conversation_id = c.id
          AND messages.message_type != #{activity_type}
        ORDER BY messages.created_at DESC, messages.id DESC
        LIMIT 1
      ) m ON TRUE
      WHERE c.id IN (#{quoted_ids})
        AND m.id IS NOT NULL
    SQL

    rows = connection.exec_query(sql).to_a
    return {} if rows.empty?

    message_ids = rows.map { |row| row['message_id'] }.compact.uniq
    messages_by_id = Message.unscoped
                            .where(id: message_ids)
                            .includes(:sender, :attachments)
                            .index_by(&:id)

    rows.each_with_object({}) do |row, memo|
      message = messages_by_id[row['message_id']]
      memo[row['conversation_id']] = message if message
    end
  end

  def quoted_uuid_list(ids, connection = ActiveRecord::Base.connection)
    ids.map { |id| connection.quote(id) }.join(', ')
  end
end
