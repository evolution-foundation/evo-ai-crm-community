# Anonymous connections are intentionally allowed: identity is proven per channel, not
# per connection. A widget contact presents the contact_inbox pubsub_token; an agent
# presents the auth-service access_token (RoomChannel, CRM-537). `warden_user` is inert —
# this app mounts no Warden middleware — and is kept only so the connection identifier
# the framework stamps on live connections does not change.
class ApplicationCable::Connection < ActionCable::Connection::Base
  identified_by :warden_user

  def connect
    self.warden_user = env['warden']&.user
  rescue StandardError => e
    logger.warn "ActionCable connection user resolution failed: #{e.class} #{e.message}"
    self.warden_user = nil
  end
end
