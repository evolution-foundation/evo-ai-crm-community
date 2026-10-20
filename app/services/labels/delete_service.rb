class Labels::DeleteService
  pattr_initialize [:label_title!]

  def perform
    tagged_conversations.find_in_batches do |conversation_batch|
      conversation_batch.each do |conversation|
        # Route through the setter so the label_list change is dirty-tracked and
        # Conversation#create_label_change / notify_conversation_updation emit the
        # label.removed activity + CONVERSATION_UPDATED (a bare label_list.remove
        # mutates the collection without populating previous_changes[:label_list]).
        conversation.update!(label_list: conversation.label_list - [label_title])
      end
    end

    tagged_contacts.find_in_batches do |contact_batch|
      contact_batch.each do |contact|
        # Route through the setter so saved_change_to_label_list? dirty-tracks
        # the removal and Contact#publish_label_changes emits the remove event.
        contact.update!(label_list: contact.label_list - [label_title])
      end
    end

    tagged_deals.find_in_batches do |deal_batch|
      deal_batch.each do |deal|
        deal.update_deal_labels!(deal.label_list - [label_title], actor: nil, source: 'label_catalog')
      end
    end
  end

  private

  def tagged_conversations
    Conversation.tagged_with(label_title)
  end

  def tagged_contacts
    Contact.tagged_with(label_title)
  end

  def tagged_deals
    PipelineItem.tagged_with(label_title)
  end
end
