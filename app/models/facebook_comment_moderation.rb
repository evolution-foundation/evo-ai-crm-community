# == Schema Information
#
# Table name: facebook_comment_moderations
#
#  id                   :uuid             not null, primary key
#  action_type          :string           not null
#  moderated_at         :datetime
#  moderation_type      :string           not null
#  rejection_reason     :text
#  response_content     :text
#  sentiment_confidence :float            default(0.0), not null
#  sentiment_offensive  :boolean          default(FALSE), not null
#  sentiment_reason     :text
#  status               :string           default("pending"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  comment_id           :string           not null
#  conversation_id      :uuid             not null
#  message_id           :uuid             not null
#  moderated_by_id      :uuid
#
# Indexes
#
#  idx_on_status_moderation_type_4dd0516d2b               (status,moderation_type)
#  index_facebook_comment_moderations_on_comment_id       (comment_id)
#  index_facebook_comment_moderations_on_conversation_id  (conversation_id)
#  index_facebook_comment_moderations_on_message_id       (message_id)
#  index_facebook_comment_moderations_on_moderated_by_id  (moderated_by_id)
#  index_facebook_comment_moderations_on_moderation_type  (moderation_type)
#  index_facebook_comment_moderations_on_status           (status)
#
# Foreign Keys
#
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (message_id => messages.id)
#
class FacebookCommentModeration < ApplicationRecord
  include Wisper::Publisher

  belongs_to :conversation
  belongs_to :message
  belongs_to :moderated_by, class_name: 'User', optional: true

  validates :conversation_id, presence: true
  validates :message_id, presence: true
  validates :comment_id, presence: true
  validates :moderation_type, presence: true, inclusion: { in: %w[explicit_words offensive_sentiment response_approval] }
  validates :status, presence: true, inclusion: { in: %w[pending approved rejected] }
  validates :action_type, presence: true, inclusion: { in: %w[delete_comment block_user send_response] }
  validate :response_content_required_for_response_approval
  validate :rejection_reason_required_when_rejected

  # Constants for moderation types
  MODERATION_TYPES = {
    explicit_words: 'explicit_words',
    offensive_sentiment: 'offensive_sentiment',
    response_approval: 'response_approval'
  }.freeze

  # Constants for statuses
  STATUSES = {
    pending: 'pending',
    approved: 'approved',
    rejected: 'rejected'
  }.freeze

  # Constants for action types
  ACTION_TYPES = {
    delete_comment: 'delete_comment',
    block_user: 'block_user',
    send_response: 'send_response'
  }.freeze

  # Scopes
  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }
  scope :rejected, -> { where(status: 'rejected') }
  scope :for_deletion, -> { where(action_type: %w[delete_comment block_user]) }
  scope :for_response_approval, -> { where(action_type: 'send_response') }
  scope :by_moderation_type, ->(type) { where(moderation_type: type) }
  scope :recent, -> { order(created_at: :desc) }

  # Helper methods for status checks
  def pending?
    status == 'pending'
  end

  def approved?
    status == 'approved'
  end

  def rejected?
    status == 'rejected'
  end

  # Approve moderation
  def approve!(user)
    return false unless pending?

    # For response approval, ensure response_content is present
    if action_type == 'send_response' && response_content.blank?
      errors.add(:response_content, 'must be generated before approval')
      return false
    end

    self.status = 'approved'
    self.moderated_by = user
    self.moderated_at = Time.current

    if save
      publish(:facebook_comment_moderation_approved, data: { moderation: self })
      execute_action!
      true
    else
      false
    end
  end

  # Reject moderation
  def reject!(user, reason = nil)
    return false unless pending?

    self.status = 'rejected'
    self.moderated_by = user
    self.moderated_at = Time.current
    self.rejection_reason = reason if reason.present?

    if save
      publish(:facebook_comment_moderation_rejected, data: { moderation: self })

      # When rejecting offensive/explicit moderations, delete the comment from Facebook
      # This allows moderators to quickly delete comments without approving
      if for_deletion? && action_type == 'delete_comment'
        Rails.logger.info "[Facebook Moderation] Rejecting moderation #{id}, will delete comment #{comment_id} from Facebook"
        execute_delete_action!
      end

      true
    else
      false
    end
  end

  # Execute the approved action
  def execute_action!
    return unless approved?

    Rails.logger.info "[Facebook Moderation] Executing action for moderation #{id}: action_type=#{action_type}, comment_id=#{comment_id}, moderation_type=#{moderation_type}"

    executor = Facebook::Moderation::ActionExecutorService.new(self)

    result = case action_type
    when 'delete_comment'
      # For explicit_words or offensive_sentiment moderations that are approved,
      # don't delete the comment - instead generate a response from the AI
      # The moderator approved it, meaning they want the AI to respond despite the flags
      if for_deletion? && (moderation_type == 'explicit_words' || moderation_type == 'offensive_sentiment')
        Rails.logger.info "[Facebook Moderation] Moderation approved - will generate AI response instead of deleting"
        generate_ai_response
      else
        Rails.logger.info "[Facebook Moderation] Executing delete_comment action"
        executor.delete_comment
      end
    when 'block_user'
      Rails.logger.info "[Facebook Moderation] Executing block_user action"
      executor.block_user
    when 'send_response'
      Rails.logger.info "[Facebook Moderation] Executing send_response action"
      executor.send_response
    else
      Rails.logger.warn "[Facebook Moderation] Unknown action_type: #{action_type}"
      false
    end

    Rails.logger.info "[Facebook Moderation] Action execution result: #{result.inspect}"
    result
  end

  # Check if moderation is for deletion (explicit words or offensive sentiment)
  def for_deletion?
    %w[explicit_words offensive_sentiment].include?(moderation_type)
  end

  # Check if moderation is for response approval
  def for_response_approval?
    moderation_type == 'response_approval'
  end

  # Execute delete action when rejecting moderation
  # This allows moderators to delete comments by rejecting the moderation
  def execute_delete_action!
    return unless action_type == 'delete_comment'

    Rails.logger.info "[Facebook Moderation] Executing delete action for rejected moderation #{id}: action_type=#{action_type}, comment_id=#{comment_id}"

    executor = Facebook::Moderation::ActionExecutorService.new(self)

    # Delete comment and all its replies from Facebook
    # The delete_comment method already handles deleting reply messages
    facebook_result = executor.delete_comment

    # Then delete the main message from the system
    # Note: Reply messages are already deleted by delete_comment method
    if facebook_result && message.present?
      Rails.logger.info "[Facebook Moderation] Deleting message #{message.id} from system after Facebook deletion"
      begin
        # Delete moderation records first
        FacebookCommentModeration.where(message: message).destroy_all
        message.destroy
        Rails.logger.info "[Facebook Moderation] Message #{message.id} deleted successfully from system"
      rescue StandardError => e
        Rails.logger.error "[Facebook Moderation] Error deleting message #{message.id} from system: #{e.message}"
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end

    Rails.logger.info "[Facebook Moderation] Delete action execution result: #{facebook_result.inspect}"
    facebook_result
  end

  # Generate AI response for approved explicit_words or offensive_sentiment moderations
  # When a moderator approves a flagged comment, we generate a response as if it passed moderation
  def generate_ai_response
    return false unless message.present?
    return false unless conversation.present?

    Rails.logger.info "[Facebook Moderation] Generating AI response for approved moderation #{id}"

    # Find the agent bot for this conversation
    agent_bot_inbox = conversation.inbox.agent_bot_inbox
    return false unless agent_bot_inbox.present?

    agent_bot = agent_bot_inbox.agent_bot_for_conversation(conversation)
    return false unless agent_bot.present?

    Rails.logger.info "[Facebook Moderation] Using agent bot: #{agent_bot.name} (ID: #{agent_bot.id})"

    # Queue response generation job
    # This will generate the response and create a moderation record for approval if needed
    Facebook::Moderation::GenerateResponseJob.perform_later(
      message.id,
      conversation.id,
      agent_bot.id,
      {
        offensive: sentiment_offensive || false,
        confidence: sentiment_confidence || 0.0,
        reason: sentiment_reason
      }
    )

    Rails.logger.info "[Facebook Moderation] AI response generation queued for message #{message.id}"
    true
  rescue StandardError => e
    Rails.logger.error "[Facebook Moderation] Error generating AI response: #{e.message}"
    Rails.logger.error(e.backtrace.join("\n"))
    false
  end

  private

  def response_content_required_for_response_approval
    return unless action_type == 'send_response'
    # Allow nil initially (placeholder record), but require it when approving
    return if response_content.present? || status == 'pending'

    errors.add(:response_content, 'is required for response approval')
  end

  def rejection_reason_required_when_rejected
    return unless status == 'rejected'
    # Allow rejection without reason (rejection_reason can be nil or empty string)
    # This validation is intentionally lenient to allow quick rejections
  end
end

