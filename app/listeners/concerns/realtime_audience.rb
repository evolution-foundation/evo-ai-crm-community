# frozen_string_literal: true

# Whoever can read a conversation over HTTP gets its realtime frames: inbox
# members plus administrators (User#assigned_inboxes opens Inbox.all to them).
# The audience is widened HERE, in what the events hand to user_tokens, never
# inside user_tokens: a consumer intersecting user_tokens with the given agents
# keeps working and the wider set survives (CRM-546).
module RealtimeAudience
  READERS_CACHE_KEY = 'action_cable_listener:reader_ids'
  READERS_CACHE_TTL = 30.seconds

  private

  def audience(conversation)
    (conversation.inbox.members.to_a + realtime_readers(conversation)).uniq
  end

  # Administrators by role. Its own seam so a consumer can narrow it (per
  # agency/tenant, in SQL); it only needs pubsub_token on the returned users.
  # Ids cached briefly: a rotated pubsub_token goes stale for READERS_CACHE_TTL at most.
  def realtime_readers(_conversation)
    ids = Rails.cache.fetch(READERS_CACHE_KEY, expires_in: READERS_CACHE_TTL) do
      User.joins(:roles).where(roles: { key: Role::ADMIN_ROLE_KEYS }).distinct.pluck(:id)
    end
    ids.empty? ? [] : User.where(id: ids).to_a
  end
end
