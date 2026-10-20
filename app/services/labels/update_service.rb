class Labels::UpdateService
  pattr_initialize [:new_label_title!, :old_label_title!]

  def perform
    # Rename to the same title is a no-op; skip to avoid spurious
    # remove/add Wisper churn through Contact#publish_label_changes.
    return if old_label_title == new_label_title

    tagged_conversations.find_in_batches do |conversation_batch|
      conversation_batch.each do |conversation|
        conversation.label_list.remove(old_label_title)
        conversation.label_list.add(new_label_title)
        conversation.save!
      end
    end

    tagged_contacts.find_in_batches do |contact_batch|
      contact_batch.each do |contact|
        # F-2: route through the setter so
        # `saved_change_to_label_list?` dirty-tracks the change and
        # Contact#publish_label_changes emits the add/remove events.
        contact.update!(label_list: contact.label_list - [old_label_title] + [new_label_title])
      end
    end

    tagged_deals.find_in_batches do |deal_batch|
      deal_batch.each do |deal|
        deal.update_deal_labels!(
          deal.label_list - [old_label_title] + [new_label_title], actor: nil, source: 'label_catalog'
        )
      end
    end
  end

  private

  def tagged_conversations
    Conversation.tagged_with(old_label_title)
  end

  def tagged_contacts
    Contact.tagged_with(old_label_title)
  end

  def tagged_deals
    PipelineItem.tagged_with(old_label_title)
  end
end
