# Service to find or create a conversation for a Facebook post
# All comments on the same post will be grouped in the same conversation
# Uses the contact of the user who commented, not a special post contact
class Facebook::PostConversationService
  attr_reader :inbox, :post_id, :is_boosted, :contact_inbox

  def initialize(inbox:, post_id:, is_boosted: false, contact_inbox: nil)
    @inbox = inbox
    @post_id = post_id
    @is_boosted = is_boosted
    @contact_inbox = contact_inbox
  end

  def perform
    find_or_create_post_conversation
  end

  private

  def find_or_create_post_conversation
    # Find existing conversation for this post
    existing_conversation = find_existing_conversation

    if existing_conversation
      # Update post data if needed
      update_post_data(existing_conversation)
      return existing_conversation
    end

    # Create new conversation for this post
    create_post_conversation
  end

  def find_existing_conversation
    # Find conversation by post_id in additional_attributes
    # All conversations for the same post share the same post_id
    Conversation.where(inbox_id: inbox.id)
                .where("additional_attributes->>'conversation_type' = ?", 'post')
                .where("additional_attributes->>'post_id' = ?", post_id)
                .first
  end

  def create_post_conversation
    ActiveRecord::Base.transaction do
      # Use provided contact_inbox or get the first contact from existing messages
      user_contact_inbox = contact_inbox || find_first_commenter_contact_inbox

      unless user_contact_inbox
        Rails.logger.error("Facebook::PostConversationService: No contact_inbox provided and no existing contact found for post #{post_id}")
        return nil
      end

      # Fetch post data from Facebook
      post_data = fetch_post_data

      # Create conversation with user's contact
      conversation = Conversation.create!(
        inbox_id: inbox.id,
        contact_id: user_contact_inbox.contact_id,
        contact_inbox_id: user_contact_inbox.id,
        status: :open,
        additional_attributes: {
          conversation_type: 'post',
          post_id: post_id,
          is_boosted: is_boosted,
          post_data: post_data
        }
      )

      Rails.logger.info("Facebook::PostConversationService: Created conversation #{conversation.id} for post #{post_id} with contact #{user_contact_inbox.contact_id}")

      conversation
    end
  end

  def find_first_commenter_contact_inbox
    # Try to find an existing conversation for this post and get its contact_inbox
    existing_conversation = Conversation.where(inbox_id: inbox.id)
                                       .where("additional_attributes->>'post_id' = ?", post_id)
                                       .first

    return existing_conversation.contact_inbox if existing_conversation

    nil
  end

  def fetch_post_data
    return {} unless inbox.channel.is_a?(Channel::FacebookPage)

    Rails.logger.info("Facebook::PostConversationService: Fetching post data for post_id: #{post_id}")

    post_data = Facebook::FetchPostDataService.new(
      channel: inbox.channel,
      post_id: post_id
    ).perform

    Rails.logger.info("Facebook::PostConversationService: Fetched post data: #{post_data.inspect}")
    Rails.logger.info("Facebook::PostConversationService: Post data keys: #{post_data.keys.join(', ')}")
    Rails.logger.info("Facebook::PostConversationService: Post data empty? #{post_data.empty?}")

    post_data
  rescue StandardError => e
    Rails.logger.error("Facebook::PostConversationService: Error fetching post data: #{e.message}")
    Rails.logger.error("Facebook::PostConversationService: Error backtrace: #{e.backtrace.first(5).join("\n")}")
    {}
  end

  def update_post_data(conversation)
    # Update post data if it's missing or empty
    existing_post_data = conversation.additional_attributes&.dig('post_data')

    # Only update if post_data is missing or empty
    if existing_post_data.present? && existing_post_data.is_a?(Hash) && !existing_post_data.empty?
      Rails.logger.info("Facebook::PostConversationService: Post data already exists for conversation #{conversation.id}, skipping update")
      return
    end

    Rails.logger.info("Facebook::PostConversationService: Post data missing or empty for conversation #{conversation.id}, fetching...")
    post_data = fetch_post_data

    if post_data.empty?
      Rails.logger.warn("Facebook::PostConversationService: Fetched post data is empty for conversation #{conversation.id}")
      return
    end

    conversation.additional_attributes ||= {}
    conversation.additional_attributes['post_data'] = post_data
    conversation.save! if conversation.changed?

    Rails.logger.info("Facebook::PostConversationService: Updated post data for conversation #{conversation.id}")
  end

  def account
    RuntimeConfig.account
  end
end

