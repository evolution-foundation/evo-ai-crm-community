class DealConversation < ApplicationRecord
  belongs_to :pipeline_item
  belongs_to :conversation

  validates :conversation_id, uniqueness: { scope: :pipeline_item_id }
  after_create :attach_conversation_contact

  private

  def attach_conversation_contact
    pipeline_item.attach_contact!(conversation.contact) if conversation.contact
  end
end
