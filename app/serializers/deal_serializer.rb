# frozen_string_literal: true

module DealSerializer
  extend self

  def serialize(deal, include_details: true, labels_by_title: nil, task_counts_by_item: nil)
    labels_by_title ||= Label.all.index_by { |label| label.title.to_s.downcase }
    contacts = associated_records(deal, :contacts)
    conversations = associated_records(deal, :conversations)
    primary_contact = deal.primary_contact || contacts.first || deal.contact
    latest_message = conversations.filter_map { |conversation| latest_chat_message(conversation) }.max_by(&:created_at)

    result = PipelineItemSerializer.serialize(
      deal,
      include_entity: true,
      include_tasks_info: true,
      include_services_info: true,
      include_labels: true,
      labels_by_title: labels_by_title,
      labels_by_id: labels_by_title.values.index_by { |label| label.id.to_s },
      task_counts_by_item: task_counts_by_item
    ).merge(
      deal_id: deal.id,
      title: deal.title,
      value: deal.deal_value.to_f,
      currency: deal.currency,
      notes: deal.notes,
      owner: user_data(deal.owner),
      company: contact_data(deal.company, labels_by_title: labels_by_title),
      primary_contact: contact_data(primary_contact, include_labels: true, labels_by_title: labels_by_title),
      contact_count: contacts.length,
      conversation_count: conversations.length,
      file_count: associated_records(deal, :attachments).length,
      latest_message: message_data(latest_message)
    )

    return result unless include_details

    result.merge(
      contacts: contacts.map { |contact| contact_data(contact, include_labels: true, labels_by_title: labels_by_title) },
      conversations: conversations.map { |conversation| conversation_data(conversation, labels_by_title: labels_by_title) },
      tasks: associated_records(deal, :tasks).map { |task| task.as_json },
      scheduled_actions: ScheduledActionSerializer.serialize_collection(associated_records(deal, :scheduled_actions)),
      files: associated_records(deal, :attachments).map { |attachment| attachment_data(attachment) },
      history: history_data(deal)
    )
  end

  def serialize_collection(deals, **options)
    records = deals.to_a
    labels_by_title = Label.all.index_by { |label| label.title.to_s.downcase }
    task_counts_by_item = PipelineItemSerializer.task_counts_for(records)
    records.map do |deal|
      serialize(deal, **options, labels_by_title: labels_by_title, task_counts_by_item: task_counts_by_item)
    end
  end

  def attachment_data(attachment)
    {
      id: attachment.id,
      name: attachment.file.attached? ? attachment.file.filename.to_s : attachment.fallback_title,
      content_type: attachment.file.attached? ? attachment.file.content_type : nil,
      byte_size: attachment.file.attached? ? attachment.file.byte_size : nil,
      file_type: attachment.file_type,
      url: attachment.file_url,
      thumbnail_url: attachment.thumb_url,
      created_at: attachment.created_at.iso8601
    }
  end

  private

  def associated_records(record, association)
    relation = record.public_send(association)
    relation.to_a
  end

  def latest_chat_message(conversation)
    messages = conversation.association(:messages).loaded? ? conversation.messages : conversation.messages.chat
    messages.reject { |message| message.message_type == 'activity' || message.private? }.max_by(&:created_at)
  end

  def message_data(message)
    return nil unless message

    content = ActionController::Base.helpers.strip_tags(message.content.to_s).squish
    {
      id: message.id,
      content: content.first(280),
      message_type: message.message_type,
      created_at: message.created_at.iso8601,
      conversation_id: message.conversation_id
    }
  end

  def contact_data(contact, include_labels: false, labels_by_title: nil)
    return nil unless contact

    ContactSerializer.serialize(contact, include_labels: include_labels, labels_by_title: labels_by_title)
                     .merge('avatar_url' => contact.avatar_url.presence)
  end

  def user_data(user)
    return nil unless user

    { id: user.id, name: user.name, email: user.email, avatar_url: user.avatar_url }
  end

  def conversation_data(conversation, labels_by_title: nil)
    {
      id: conversation.id,
      display_id: conversation.display_id,
      status: conversation.status,
      inbox_id: conversation.inbox_id,
      contact: contact_data(conversation.contact, labels_by_title: labels_by_title),
      latest_message: message_data(latest_chat_message(conversation))
    }
  end

  def history_data(deal)
    audit_events = associated_records(deal, :deal_history_events).map do |event|
      {
        id: event.id,
        action: event.action,
        source: event.source,
        changes: event.change_set,
        metadata: event.metadata,
        actor: user_data(event.actor),
        created_at: event.created_at.iso8601
      }
    end
    movement_events = associated_records(deal, :stage_movements).map do |movement|
      {
        id: movement.id,
        action: 'stage_moved',
        source: movement.movement_type,
        changes: { previous: movement.from_stage_id, current: movement.to_stage_id },
        metadata: { notes: movement.notes, from_stage: movement.from_stage&.name, to_stage: movement.to_stage&.name },
        actor: user_data(movement.moved_by),
        created_at: movement.created_at.iso8601
      }
    end
    (audit_events + movement_events).sort_by { |event| event[:created_at] }.reverse
  end
end
