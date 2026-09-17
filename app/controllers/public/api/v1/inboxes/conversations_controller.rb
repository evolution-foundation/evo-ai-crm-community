class Public::Api::V1::Inboxes::ConversationsController < Public::Api::V1::InboxesController
  include Events::Types
  include ConversationResolver
  before_action :set_conversation, only: [:toggle_typing, :update_last_seen, :show, :toggle_status]
  before_action :reject_if_inbox_archived, only: [:create]

  def index
    @conversations = @contact_inbox.hmac_verified? ? @contact.conversations : @contact_inbox.conversations
  end

  def show; end

  def create
    @conversation = create_conversation
  end

  def toggle_status
    # Check if the conversation is already resolved to prevent redundant operations
    return if @conversation.resolved?

    # Assign the conversation's contact as the resolver
    # This step attributes the resolution action to the contact involved in the conversation
    # If this assignment is not made, the system implicitly becomes the resolver by default
    Current.contact = @conversation.contact

    # Update the conversation's status to 'resolved' to reflect its closure
    @conversation.status = :resolved
    @conversation.save!
  end

  def toggle_typing
    case params[:typing_status]
    when 'on'
      trigger_typing_event(CONVERSATION_TYPING_ON)
    when 'recording'
      trigger_typing_event(CONVERSATION_RECORDING)
    when 'off'
      trigger_typing_event(CONVERSATION_TYPING_OFF)
    end
    head :ok
  end

  def update_last_seen
    @conversation.contact_last_seen_at = DateTime.now.utc
    @conversation.save!
    ::Conversations::UpdateMessageStatusJob.perform_later(@conversation.id, @conversation.contact_last_seen_at)
    head :ok
  end

  private

  def set_conversation
    @conversation = if @contact_inbox.hmac_verified?
                      resolve_public_conversation_for_contact(params[:id])
                    else
                      resolve_public_conversation_for_inbox(params[:id])
                    end
    raise ActiveRecord::RecordNotFound if @conversation.nil?
  end

  def resolve_public_conversation_for_contact(conversation_param)
    if uuid_format?(conversation_param)
      @contact_inbox.contact.conversations.find_by(id: conversation_param) ||
        @contact_inbox.contact.conversations.find_by(uuid: conversation_param)
    else
      @contact_inbox.contact.conversations.find_by!(display_id: conversation_param)
    end
  end

  def resolve_public_conversation_for_inbox(conversation_param)
    if uuid_format?(conversation_param)
      @contact_inbox.conversations.find_by(id: conversation_param) ||
        @contact_inbox.conversations.find_by(uuid: conversation_param)
    else
      @contact_inbox.conversations.find_by!(display_id: conversation_param)
    end
  end

  def create_conversation
    ConversationBuilder.new(params: conversation_params, contact_inbox: @contact_inbox).perform
  end

  def trigger_typing_event(event)
    Rails.configuration.dispatcher.dispatch(event, Time.zone.now, conversation: @conversation, user: @conversation.contact)
  end

  def conversation_params
    params.permit(custom_attributes: {})
  end
end
