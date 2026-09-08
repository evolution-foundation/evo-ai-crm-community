class RoomChannel < ApplicationCable::Channel
  class SubscriptionRejected < StandardError; end

  def subscribed
    Rails.logger.info "RoomChannel subscription requested user_id=#{params[:user_id]}"
    @current_user = resolve_current_user
    ensure_stream
    update_subscription
    broadcast_presence
    Rails.logger.info "RoomChannel subscription successful user_id=#{@current_user.id}"
  rescue StandardError => e
    reject_with(e)
  end

  # Rescued locally: an exception escaping a channel action makes ActionCable log the
  # whole identifier, access_token included.
  def update_presence
    update_subscription
    broadcast_presence
  rescue StandardError => e
    Rails.logger.warn "RoomChannel update_presence failed for #{current_user&.class&.name} #{current_user&.id}: #{e.class} #{e.message}"
  end

  private

  attr_reader :current_user

  def reject_with(error)
    case error
    when ActiveRecord::RecordNotFound, SubscriptionRejected
      Rails.logger.warn "RoomChannel subscription rejected: #{error.class} #{error.message}"
    when EvoAuthService::AuthenticationError
      Rails.logger.error "RoomChannel subscription rejected, auth service unavailable: #{error.message}"
    else
      Rails.logger.error "RoomChannel subscription failed: #{error.class} #{error.message}"
      Rails.logger.error error.backtrace.join("\n")
    end
    reject
  end

  def broadcast_presence
    data = { users: ::OnlineStatusTracker.get_available_users }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts if @current_user.is_a? User
    ActionCable.server.broadcast(@stream_pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    stream_from @stream_pubsub_token
  end

  def update_subscription
    ::OnlineStatusTracker.update_presence(@current_user.class.name, @current_user.id)
  end

  def resolve_current_user
    params[:user_id].blank? ? resolve_contact : resolve_agent
  end

  # Widget visitors have no session: the contact_inbox pubsub_token is their credential.
  def resolve_contact
    contact_inbox = ContactInbox.find_by!(pubsub_token: params[:pubsub_token].to_s)
    @stream_pubsub_token = contact_inbox.pubsub_token
    contact_inbox.contact
  end

  # Agents prove identity with the auth-service token, the same credential HTTP
  # accepts (CRM-537). pubsub_token only names the stream: a stale one (rotation)
  # is replaced by the user's current token, never trusted on its own.
  def resolve_agent
    requested_id = params[:user_id].to_s
    user = resolve_agent_identity(params[:access_token].to_s, requested_id)
    raise SubscriptionRejected, "user_id mismatch requested=#{requested_id} authenticated=#{user.id}" unless user.id.to_s == requested_id

    Rails.logger.warn "RoomChannel token mismatch for user_id=#{user.id}; using current token" if params[:pubsub_token].to_s != user.pubsub_token.to_s
    @stream_pubsub_token = user.pubsub_token
    user
  end

  def resolve_agent_identity(token, requested_id)
    EvoAuth::IdentityResolver.call(token: token, token_type: params[:token_type].presence || 'bearer').user
  rescue EvoAuthService::ValidationError => e
    raise SubscriptionRejected, "invalid access_token for user_id=#{requested_id}: #{e.message}"
  end
end
