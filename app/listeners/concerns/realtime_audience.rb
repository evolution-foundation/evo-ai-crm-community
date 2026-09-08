# frozen_string_literal: true

# Whoever can read a conversation over HTTP gets its realtime frames: inbox
# members plus administrators (User#assigned_inboxes opens Inbox.all to them).
# The audience is widened HERE, in what the events hand to user_tokens, never
# inside user_tokens: a consumer intersecting user_tokens with the given agents
# keeps working and the wider set survives (CRM-546).
module RealtimeAudience
  READERS_CACHE_KEY = 'action_cable_listener:reader_ids'
  READERS_CACHE_TTL = 30.seconds
  # Same rule the auth uses to pick a user's effective role (User#primary_user_role):
  # derived roles last, then the newest grant, then the key. An older admin row that
  # outlived a demotion is a role the user no longer holds.
  DERIVED_ROLE_KEY_PREFIX = 'evo_derived_'

  private

  def audience(conversation)
    (conversation.inbox.members.to_a + realtime_readers(conversation)).uniq
  end

  # Administrators by role. Its own seam so a consumer can narrow it (per
  # agency/tenant, in SQL); it only needs pubsub_token on the returned users.
  # Ids cached briefly: a rotated pubsub_token goes stale for READERS_CACHE_TTL at most.
  def realtime_readers(_conversation)
    ids = Rails.cache.fetch(READERS_CACHE_KEY, expires_in: READERS_CACHE_TTL) { administrator_ids }
    ids.empty? ? [] : User.where(id: ids).to_a
  end

  def administrator_ids
    derived_last = "starts_with(roles.key, #{UserRole.connection.quote(DERIVED_ROLE_KEY_PREFIX)})"
    primary_roles = UserRole.joins(:role)
                            .select('DISTINCT ON (user_roles.user_id) user_roles.user_id, roles.key AS role_key')
                            .order(Arel.sql("user_roles.user_id, #{derived_last}, user_roles.created_at DESC, roles.key DESC"))
    UserRole.from(primary_roles, :primary_roles)
            .where(primary_roles: { role_key: Role::ADMIN_ROLE_KEYS })
            .pluck(Arel.sql('primary_roles.user_id'))
  end
end
