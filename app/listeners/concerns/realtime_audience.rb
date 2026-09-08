# frozen_string_literal: true

# Inbox members plus administrators — whoever reads the conversation over HTTP
# (User#assigned_inboxes). Widened HERE and never inside user_tokens, so a consumer
# intersecting user_tokens with the given agents keeps working (CRM-546).
module RealtimeAudience
  READERS_CACHE_KEY = 'action_cable_listener:reader_ids'
  READERS_CACHE_TTL = 30.seconds
  # A demotion leaves the old grant in place (the auth destroys only non-system
  # rows), so one row per user: derived keys last, newest grant first.
  DERIVED_ROLE_KEY_PREFIX = 'evo_derived_'
  # A column left out raises MissingAttributeError on access; the enterprise reads agency_id.
  READER_COLUMNS = %w[id pubsub_token agency_id].freeze

  private

  def audience(conversation)
    (conversation.inbox.members.to_a + realtime_readers(conversation)).uniq
  end

  # The seam a consumer narrows (per agency/tenant, in SQL).
  def realtime_readers(_conversation)
    ids = Rails.cache.fetch(READERS_CACHE_KEY, expires_in: READERS_CACHE_TTL) { administrator_ids }
    ids.empty? ? [] : User.where(id: ids).select(*reader_columns).to_a
  end

  # agency_id is a consumer's column: absent from a community install.
  def reader_columns
    @reader_columns ||= READER_COLUMNS & User.column_names
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
