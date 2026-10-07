require 'timeout'

class MessageTemplates::Template::CsatSurvey
  pattr_initialize [:conversation!]

  def perform
    return unless should_send_csat_survey?

    ActiveRecord::Base.transaction do
      conversation.messages.create!(csat_survey_message_params)
    end
  end

  private

  delegate :contact, :account, :inbox, to: :conversation

  def should_send_csat_survey?
    return true unless survey_rules_configured?

    evaluate_triggers
  end

  def survey_rules_configured?
    return false if csat_config.blank?
    return false if csat_config['survey_rules'].blank?

    triggers_list = triggers
    return false if triggers_list.empty?

    true
  end

  def triggers
    survey_rules = csat_config['survey_rules'] || {}
    triggers_list = survey_rules['triggers'] || survey_rules[:triggers]

    if triggers_list.present? && triggers_list.is_a?(Array)
      triggers_list.map do |trigger|
        case trigger
        when Hash
          trigger.with_indifferent_access
        else
          trigger.to_h.with_indifferent_access
        end
      end
    elsif survey_rules['operator'].present? || survey_rules[:operator].present?
      operator = survey_rules['operator'] || survey_rules[:operator] || 'contains'
      values = survey_rules['values'] || survey_rules[:values] || []
      return [] if values.empty?

      [
        {
          'type' => 'label',
          'operator' => operator,
          'values' => values
        }.with_indifferent_access
      ]
    else
      []
    end
  end

  def evaluate_triggers
    triggers_list = triggers
    return true if triggers_list.empty?

    triggers_list.any? { |trigger| evaluate_single_trigger(trigger) }
  end

  def evaluate_single_trigger(trigger)
    case trigger['type'] || trigger[:type]
    when 'label'
      evaluate_label_trigger(trigger)
    when 'stage'
      evaluate_stage_trigger(trigger)
    when 'regex'
      evaluate_regex_trigger(trigger)
    when 'inactivity'
      evaluate_inactivity_trigger(trigger)
    else
      true
    end
  end

  def evaluate_label_trigger(trigger)
    labels = conversation.label_list
    operator = trigger['operator'] || trigger[:operator] || 'contains'
    values = trigger['values'] || trigger[:values] || []

    return true if values.empty?

    case operator
    when 'contains'
      values.any? { |label| labels.include?(label) }
    when 'does_not_contain'
      values.none? { |label| labels.include?(label) }
    else
      true
    end
  end

  def evaluate_stage_trigger(trigger)
    pipeline_item = conversation.pipeline_items.first
    return false unless pipeline_item

    stage_ids = trigger['stage_ids'] || trigger[:stage_ids] || []
    stage_names = trigger['stage_names'] || trigger[:stage_names] || []
    operator = trigger['operator'] || trigger[:operator] || 'equals'

    return true if stage_ids.empty? && stage_names.empty?

    current_stage_id = pipeline_item.pipeline_stage_id&.to_s
    current_stage_name = pipeline_item.pipeline_stage&.name

    case operator
    when 'equals'
      stage_ids.include?(current_stage_id) || stage_names.include?(current_stage_name)
    when 'not_equals'
      !stage_ids.include?(current_stage_id) && !stage_names.include?(current_stage_name)
    else
      true
    end
  end

  def evaluate_regex_trigger(trigger)
    field = trigger['field'] || trigger[:field] || 'message_content'
    pattern = trigger['pattern'] || trigger[:pattern]

    return false if pattern.blank?
    return false if pattern.length > 200

    regex = Regexp.new(pattern, Regexp::IGNORECASE) rescue nil
    return false unless regex

    case field
    when 'message_content'
      last_message = conversation.messages.reorder(created_at: :desc, id: :desc).first
      return false unless last_message

      content = last_message.content.to_s
      return false if content.length > 10_000

      Timeout.timeout(1) do
        regex.match?(content)
      end
    else
      false
    end
  rescue Timeout::Error
    Rails.logger.warn "CSAT regex trigger timeout for pattern: #{pattern[0..50]}..."
    false
  end

  def evaluate_inactivity_trigger(trigger)
    minutes = trigger['minutes'] || trigger[:minutes]
    return false unless minutes.is_a?(Numeric) && minutes > 0

    last_activity_at = conversation.last_activity_at || conversation.updated_at
    return false unless last_activity_at

    inactive_minutes = (Time.current - last_activity_at) / 60
    inactive_minutes >= minutes
  end

  def message_content
    return I18n.t('conversations.templates.csat_input_message_body') if csat_config.blank? || csat_config['message'].blank?

    csat_config['message']
  end

  def csat_survey_message_params
    {
      inbox_id: @conversation.inbox_id,
      message_type: :template,
      content_type: :input_csat,
      content: message_content,
      content_attributes: content_attributes
    }
  end

  def csat_config
    inbox.csat_config || {}
  end

  def content_attributes
    {
      display_type: csat_config['display_type'] || 'emoji'
    }
  end
end
