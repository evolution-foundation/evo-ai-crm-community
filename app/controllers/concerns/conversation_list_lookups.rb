# Per-request lookups every conversation LIST shares: unread counts, latest
# message, label indexes and the page meta. They are batched by conversation
# id so the query count does not follow the number of rows on the page.
module ConversationListLookups
  extend ActiveSupport::Concern

  private

  def unread_counts_map(conversation_ids)
    return {} if conversation_ids.blank?

    connection = ActiveRecord::Base.connection
    quoted_ids = quoted_uuid_list(conversation_ids, connection)
    incoming_type = Message.message_types[:incoming]

    sql = <<~SQL.squish
      SELECT c.id AS conversation_id,
             (
               SELECT COUNT(*)
               FROM messages m
               WHERE m.conversation_id = c.id
                 AND m.message_type = #{incoming_type}
                 AND m.created_at > COALESCE(c.agent_last_seen_at, to_timestamp(0))
                 AND (m.content_attributes->>'read') IS DISTINCT FROM 'true'
             )::integer AS unread_count
      FROM conversations c
      WHERE c.id IN (#{quoted_ids})
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

  def labels_by_title
    label_indexes[:by_title]
  end

  def labels_by_id
    label_indexes[:by_id]
  end

  def label_indexes
    @label_indexes ||= Labels::TagChipResolver.indexes_for(Label.all.to_a)
  end

  # Keys mirror the main conversation list, so a client pages both the same way.
  def conversation_page_meta(paginated)
    {
      total_count: paginated.total_count,
      current_page: paginated.current_page,
      per_page: paginated.limit_value,
      total: paginated.total_count,
      total_pages: paginated.total_pages,
      has_next_page: paginated.current_page < paginated.total_pages,
      has_previous_page: paginated.current_page > 1
    }
  end

  def quoted_uuid_list(ids, connection = ActiveRecord::Base.connection)
    ids.map { |id| connection.quote(id) }.join(', ')
  end
end
