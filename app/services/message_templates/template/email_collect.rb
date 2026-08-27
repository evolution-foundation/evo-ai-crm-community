class MessageTemplates::Template::EmailCollect
  pattr_initialize [:conversation!]

  def perform
    ActiveRecord::Base.transaction do
      conversation.messages.create!(ways_to_reach_you_message_params)
      conversation.messages.create!(email_input_box_template_message_params)
    end
  rescue StandardError => e
    EvolutionExceptionTracker.new(e, account: nil).capture_exception
    true
  end

  private

  delegate :contact, to: :conversation
  delegate :inbox, to: :message

  def ways_to_reach_you_message_params
    brand_name = GlobalConfig.get('BRAND_NAME')['BRAND_NAME'].presence || 'AutomaLead'
    content = I18n.t('conversations.templates.ways_to_reach_you_message_body',
                     account_name: brand_name)

    {
      inbox_id: @conversation.inbox_id,
      message_type: :template,
      content: content
    }
  end

  def email_input_box_template_message_params
    brand_name = GlobalConfig.get('BRAND_NAME')['BRAND_NAME'].presence || 'AutomaLead'
    content = I18n.t('conversations.templates.email_input_box_message_body',
                     account_name: brand_name)

    {
      inbox_id: @conversation.inbox_id,
      message_type: :template,
      content_type: :input_email,
      content: content
    }
  end
end
