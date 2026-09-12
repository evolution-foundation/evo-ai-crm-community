# Resolves the Conversation a stage inactivity rule should act on.
#
# - If the pipeline_item is conversation-anchored and the conversation is
#   open/pending, use it.
# - Otherwise (contact-only lead, or no live conversation) optionally CREATE a
#   conversation so the message has a target — but only behind guards, since
#   creating a conversation sends a real, active message to the contact.
#
# Guards (finding #3/#4 from the adversarial review):
#   * Only WhatsApp providers that allow free-text active messaging
#     (evolution / evolution_go) may be created for non-template
#     actions. Cloud/360 require a template, so creation is only allowed when
#     the action is `send_template`.
#   * The created conversation is tagged so AgentBotListener / account
#     automations ignore it and do not double-engage on `conversation_created`.
class Pipelines::StageInactivityTargetResolver
  FREE_TEXT_PROVIDERS = %w[evolution evolution_go].freeze
  CREATED_BY = 'stage_inactivity'.freeze

  Result = Struct.new(:conversation, :created, :requires_template, keyword_init: true)

  def initialize(pipeline_item)
    @pipeline_item = pipeline_item
  end

  # action: the rule action string, used to decide whether creation is allowed
  # for the resolved channel. action_value: the rule's action_value — for
  # send_template this is a MessageTemplate id, used to prefer that template's
  # own channel/inbox over the generic scan (see #template_contactable).
  # Returns a Result or nil (no usable target).
  def resolve(action, action_value = nil)
    existing = existing_conversation
    return Result.new(conversation: existing, created: false, requires_template: false) if existing

    # `finalize` has nothing to finalize without a conversation.
    return nil if action == 'finalize'

    contact = @pipeline_item.contact
    return nil if contact.nil?

    contactable = template_contactable(contact, action, action_value) || pick_contactable_inbox(contact)
    return nil if contactable.nil?

    provider = contactable[:inbox].channel.try(:provider)
    free_text = FREE_TEXT_PROVIDERS.include?(provider)

    # Cloud/360: only a template can be sent on a brand-new conversation.
    return nil if !free_text && action != 'send_template'

    conversation = create_conversation(contact, contactable)
    return nil unless conversation

    Result.new(conversation: conversation, created: true, requires_template: !free_text)
  end

  private

  def existing_conversation
    conv = @pipeline_item.conversation
    return conv if conv && (conv.open? || conv.pending?)

    nil
  end

  # A send_template rule's MessageTemplate is bound to exactly one channel/inbox whenever
  # it has a channel at all — WhatsApp Cloud enforces this (MessageTemplate#channel_
  # required_for_whatsapp_cloud), but any other WhatsApp provider (Evolution, Evolution Go,
  # Z-API, 360dialog, ...) can just as legitimately have its own per-channel templates. Use
  # that inbox directly instead of the generic contactable-inbox scan, which could pick a
  # different WhatsApp inbox on the account even though the template unambiguously names
  # its own.
  def template_contactable(contact, action, action_value)
    return nil unless action == 'send_template' && action_value.present?

    channel = MessageTemplate.find_by(id: action_value)&.channel
    return nil unless channel.is_a?(Channel::Whatsapp)

    inbox = channel.inbox
    return nil if inbox.blank? || contact.phone_number.blank?

    # Matches Contacts::ContactableInboxesService#whatsapp_contactable_inbox: WhatsApp wants
    # the phone number without the leading '+' (E.164 minus the plus).
    { inbox: inbox, source_id: contact.phone_number.delete('+') }
  end

  def pick_contactable_inbox(contact)
    Contacts::ContactableInboxesService.new(contact: contact).get.first
  rescue StandardError => e
    Rails.logger.warn "[StageInactivityTarget] contactable lookup failed for contact=#{contact.id}: #{e.message}"
    nil
  end

  def create_conversation(contact, contactable)
    contact_inbox = ContactInboxBuilder.new(
      contact: contact,
      inbox: contactable[:inbox],
      source_id: contactable[:source_id]
    ).perform
    return nil unless contact_inbox

    # ConversationBuilder expects real params (it calls `.permit!` on additional_attributes) —
    # every other caller passes an actual controller `params`; wrap ours the same way.
    ConversationBuilder.new(
      params: ActionController::Parameters.new(additional_attributes: { 'created_by' => CREATED_BY }),
      contact_inbox: contact_inbox
    ).perform
  rescue StandardError => e
    Rails.logger.error "[StageInactivityTarget] conversation create failed for item=#{@pipeline_item.id}: #{e.message}"
    nil
  end
end
