# frozen_string_literal: true

# Listener para invalidar cache quando conversas são modificadas
class Conversations::CacheInvalidationListener
  def conversation_created(conversation, account)
    invalidate_conversation_caches(conversation, account)
  end

  def conversation_updated(conversation, account, changes = {})
    # Only invalidate if relevant fields changed
    relevant_fields = %w[status assignee_id team_id]

    if changes.keys.intersect?(relevant_fields)
      invalidate_conversation_caches(conversation, account)
    end
  end

  def conversation_destroyed(conversation, account)
    invalidate_conversation_caches(conversation, account)
  end

  def message_created(message, account)
    # Message creation affects conversation counts
    invalidate_conversation_caches(message.conversation, account)
  end

  private

  def invalidate_conversation_caches(conversation, account)
    # Invalidate caches for all users that might see this conversation
    affected_users = determine_affected_users(conversation, account)

    affected_users.each do |user|
      Conversations::CachedCountService.new(user, account).invalidate_cache
    end

    # Also invalidate Redis cached conversations list
    invalidate_conversation_list_cache(conversation, account)
  end

  def determine_affected_users(conversation, account)
    users = Set.new

    # Add assignee if present
    users.add(conversation.assignee) if conversation.assignee

    # Add team members if conversation has team
    if conversation.team
      users.merge(conversation.team.team_members.includes(:user).map(&:user))
    end

    # Add all users with inbox access
    users.merge(conversation.inbox.inbox_members.includes(:user).map(&:user))

    users.merge(User.where(type: 'SuperAdmin'))

    users.compact
  end

  def invalidate_conversation_list_cache(conversation, account)
    # Clear paginated conversation lists
    pattern = "conversations:list:*"

    Redis.current.scan_each(match: pattern) do |key|
      Rails.cache.delete(key)
    end
  end
end
