class Labels::UpdateService
  pattr_initialize [:new_label_title!, :old_label_title!]

  def perform
    # Rename to the same title is a no-op; skip to avoid spurious
    # remove/add Wisper churn through Contact#publish_label_changes.
    return if old_label_title == new_label_title

    tagged_conversations.find_in_batches do |conversation_batch|
      conversation_batch.each { |conversation| rename_on(conversation) }
    end

    tagged_contacts.find_in_batches do |contact_batch|
      contact_batch.each do |contact|
        # F-2: route through the setter so
        # `saved_change_to_label_list?` dirty-tracks the change and
        # Contact#publish_label_changes emits the add/remove events.
        contact.update!(
          label_list: Labels::DeleteService.without(contact.label_list, old_label_title) + [new_label_title]
        )
      end
    end
  end

  private

  # In place, not through the setter: the setter dirty-tracks label_list and
  # would emit conversation.updated per conversation. Only the match changes:
  # `tagged_with` locates "Urgente" for "urgente", an exact remove did not.
  def rename_on(conversation)
    conversation.label_list.to_a.each do |applied|
      conversation.label_list.remove(applied) if applied.to_s.casecmp?(old_label_title.to_s)
    end
    conversation.label_list.add(new_label_title)
    conversation.save!
  end

  def tagged_conversations
    Conversation.tagged_with(old_label_title)
  end

  def tagged_contacts
    Contact.tagged_with(old_label_title)
  end
end
