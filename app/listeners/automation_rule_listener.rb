class AutomationRuleListener < BaseListener
  def conversation_updated(event)
    return if performed_by_automation?(event)

    conversation = event.data[:conversation]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('conversation_updated', account)

    rules = current_account_rules('conversation_updated', account)

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { changed_attributes: changed_attributes }).perform
      next unless conditions_match.present?
      
      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
      else
        AutomationRules::ActionService.new(rule, account, conversation).perform
      end
    end
  end

  def conversation_created(event)
    return if performed_by_automation?(event)

    conversation = event.data[:conversation]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('conversation_created', account)

    rules = current_account_rules('conversation_created', account)

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { changed_attributes: changed_attributes }).perform
      next unless conditions_match.present?
      
      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
      else
        ::AutomationRules::ActionService.new(rule, account, conversation).perform
      end
    end
  end

  def conversation_opened(event)
    return if performed_by_automation?(event)

    conversation = event.data[:conversation]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('conversation_opened', account)

    rules = current_account_rules('conversation_opened', account)

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { changed_attributes: changed_attributes }).perform
      next unless conditions_match.present?
      
      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
      else
        AutomationRules::ActionService.new(rule, account, conversation).perform
      end
    end
  end

  def message_created(event)
    message = event.data[:message]

    return if ignore_message_created_event?(event)

    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('message_created', account)

    rules = current_account_rules('message_created', account)

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, message.conversation,
                                                                        { message: message, changed_attributes: changed_attributes }).perform
      next unless conditions_match.present?
      
      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, message.conversation).perform
      else
        ::AutomationRules::ActionService.new(rule, account, message.conversation).perform
      end
    end
  end

  def pipeline_stage_updated(event)
    return if performed_by_automation?(event)

    pipeline_item = event.data[:pipeline_item]
    conversation = pipeline_item&.conversation
    account = nil
    changed_attributes = event.data[:changed_attributes] || build_default_changed_attributes(pipeline_item)

    Rails.logger.info "[AutomationRuleListener] pipeline_stage_updated received: pipeline_item=#{pipeline_item&.id} conversation=#{conversation&.id} changed_attributes=#{changed_attributes.inspect}"

    if conversation.nil?
      Rails.logger.warn "[AutomationRuleListener] pipeline_stage_updated: no conversation linked to pipeline_item #{pipeline_item&.id} — skipping (rules require a conversation)"
      return
    end

    return unless rule_present?('pipeline_stage_updated', account)

    rules = current_account_rules('pipeline_stage_updated', account)
    Rails.logger.info "[AutomationRuleListener] pipeline_stage_updated: #{rules.length} active rule(s) to evaluate for conversation #{conversation.id}"

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { changed_attributes: changed_attributes }).perform
      Rails.logger.info "[AutomationRuleListener] rule #{rule.id} '#{rule.name}' conditions_match=#{conditions_match.inspect}"
      next unless conditions_match.present?

      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
      else
        AutomationRules::ActionService.new(rule, account, conversation).perform
      end
    end
  end

  def conversation_resolved(event)
    return if performed_by_automation?(event)

    conversation = event.data[:conversation]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('conversation_resolved', account)

    rules = current_account_rules('conversation_resolved', account)

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { changed_attributes: changed_attributes }).perform
      next unless conditions_match.present?

      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
      else
        AutomationRules::ActionService.new(rule, account, conversation).perform
      end
    end
  end

  def conversation_status_changed(event)
    return if performed_by_automation?(event)

    conversation = event.data[:conversation]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('conversation_status_changed', account)

    rules = current_account_rules('conversation_status_changed', account)

    rules.each do |rule|
      conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { changed_attributes: changed_attributes }).perform
      next unless conditions_match.present?

      if rule.mode == 'flow' && rule.flow_data.present?
        AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
      else
        AutomationRules::ActionService.new(rule, account, conversation).perform
      end
    end
  end

  def contact_created(event)
    return if performed_by_automation?(event)

    contact = event.data[:contact]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('contact_created', account)

    rules = current_account_rules('contact_created', account)

    rules.each do |rule|
      # Para eventos de contato que só têm condições de contato, 
      # não precisamos de uma conversa
      if rule_has_only_contact_conditions?(rule)
        conditions_match = evaluate_contact_conditions(rule, contact, changed_attributes)
        if conditions_match
          # Executa ações que não precisam de conversa (como webhooks)
          if rule.mode == 'flow' && rule.flow_data.present?
            AutomationRules::FlowExecutionService.new(rule, account, nil, contact).perform
          else
            execute_contact_actions(rule, account, contact)
          end
        end
      else
        # Se tiver condições de conversa, precisa de uma conversa
        conversation = contact.conversations.last
        next unless conversation

        conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { contact: contact, changed_attributes: changed_attributes }).perform
        if conditions_match.present?
          if rule.mode == 'flow' && rule.flow_data.present?
            AutomationRules::FlowExecutionService.new(rule, account, conversation, contact).perform
          else
            ::AutomationRules::ActionService.new(rule, account, conversation).perform
          end
        end
      end
    end
  end

  def contact_updated(event)
    return if performed_by_automation?(event)

    contact = event.data[:contact]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    # Evitar loop infinito - múltiplas estratégias de detecção
    
    # 1. Se changed_attributes está vazio, pode ser um evento de automação não detectado
    if changed_attributes.blank? || changed_attributes.empty?
      Rails.logger.info "Automation Rule: Skipping contact_updated for contact #{contact.id} - empty changed_attributes"
      return
    end
    
    # 2. Removido a proteção excessiva de labels - automações podem ser executadas quando labels mudam
    
    # 3. Verificar se há muitos eventos recentes do mesmo contato (proteção contra spam)
    recent_events_key = "contact_updated_#{contact.id}"
    recent_count = Rails.cache.read(recent_events_key) || 0
    
    if recent_count > 5
      Rails.logger.warn "Automation Rule: Skipping contact_updated for contact #{contact.id} - too many recent events (#{recent_count})"
      return
    end
    
    # Incrementar contador de eventos recentes (expira em 30 segundos)
    Rails.cache.write(recent_events_key, recent_count + 1, expires_in: 30.seconds)

    # Log para debug das mudanças
    Rails.logger.debug "Automation Rule: Processing contact_updated for contact #{contact.id} - changed attributes: #{changed_attributes.keys.sort}"

    return unless rule_present?('contact_updated', account)

    rules = current_account_rules('contact_updated', account)

    rules.each do |rule|
      # Para eventos de contato que só têm condições de contato, 
      # não precisamos de uma conversa
      if rule_has_only_contact_conditions?(rule)
        conditions_match = evaluate_contact_conditions(rule, contact, changed_attributes)
        if conditions_match
          # Executa ações que não precisam de conversa (como webhooks)
          if rule.mode == 'flow' && rule.flow_data.present?
            AutomationRules::FlowExecutionService.new(rule, account, nil, contact).perform
          else
            execute_contact_actions(rule, account, contact)
          end
        end
      else
        # Se tiver condições de conversa, precisa de uma conversa
        conversation = contact.conversations.last
        next unless conversation

        conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { contact: contact, changed_attributes: changed_attributes }).perform
        if conditions_match.present?
          if rule.mode == 'flow' && rule.flow_data.present?
            AutomationRules::FlowExecutionService.new(rule, account, conversation, contact).perform
          else
            ::AutomationRules::ActionService.new(rule, account, conversation).perform
          end
        end
      end
    end
  end

  def rule_present?(event_name, _account = nil)
    current_account_rules(event_name).any?
  end

  def current_account_rules(event_name, _account = nil)
    AutomationRule.where(event_name: event_name, active: true)
  end

  def performed_by_automation?(event)
    event.data[:performed_by].present? && event.data[:performed_by].instance_of?(AutomationRule)
  end

  def ignore_message_created_event?(event)
    message = event.data[:message]
    performed_by_automation?(event) || message.activity?
  end

  private

  def build_default_changed_attributes(pipeline_item)
    {
      'pipeline_stage_id' => [
        pipeline_item.pipeline_stage_id_previously_was,
        pipeline_item.pipeline_stage_id
      ]
    }
  end

  def rule_has_only_contact_conditions?(rule)
    # Verifica se todas as condições são de contato
    contact_attributes = %w[name email phone_number identifier country_code city company labels blocked]
    rule.conditions.all? do |condition|
      contact_attributes.include?(condition['attribute_key'])
    end
  end

  def evaluate_contact_conditions(rule, contact, changed_attributes)
    # Avalia condições simples de contato
    rule.conditions.all? do |condition|
      attribute_key = condition['attribute_key']
      filter_operator = condition['filter_operator']
      values = condition['values']

      case attribute_key
      when 'labels'
        # Para labels, verifica se o contato tem as labels especificadas
        contact_labels = contact.label_list
        case filter_operator
        when 'equal_to'
          label_ids = values
          label_titles = Label.where(id: label_ids).pluck(:title)
          (label_titles - contact_labels).empty?
        when 'not_equal_to'
          label_ids = values
          label_titles = Label.where(id: label_ids).pluck(:title)
          (label_titles & contact_labels).empty?
        when 'is_present'
          contact_labels.any?
        when 'is_not_present'
          contact_labels.empty?
        else
          false
        end
      when 'name', 'email', 'phone_number', 'identifier'
        # Atributos simples do contato
        contact_value = contact.send(attribute_key)
        case filter_operator
        when 'equal_to'
          values.include?(contact_value)
        when 'not_equal_to'
          !values.include?(contact_value)
        when 'contains'
          values.any? { |v| contact_value&.include?(v) }
        when 'does_not_contain'
          values.none? { |v| contact_value&.include?(v) }
        when 'is_present'
          contact_value.present?
        when 'is_not_present'
          contact_value.blank?
        else
          false
        end
      when 'blocked'
        case filter_operator
        when 'equal_to'
          contact.blocked == (values.first == 'true')
        when 'not_equal_to'
          contact.blocked != (values.first == 'true')
        else
          false
        end
      when 'city', 'country_code', 'company'
        # Atributos adicionais
        contact_value = contact.additional_attributes&.dig(attribute_key)
        case filter_operator
        when 'equal_to'
          values.include?(contact_value)
        when 'not_equal_to'
          !values.include?(contact_value)
        when 'contains'
          values.any? { |v| contact_value&.include?(v) }
        when 'does_not_contain'
          values.none? { |v| contact_value&.include?(v) }
        when 'is_present'
          contact_value.present?
        when 'is_not_present'
          contact_value.blank?
        else
          false
        end
      else
        false
      end
    end
  end

  def execute_contact_actions(rule, account, contact)
    # Executa apenas ações que não precisam de conversa
    rule.actions.each do |action|
      action_name = action['action_name']
      action_params = action['action_params']

      case action_name
      when 'send_webhook_event'
        # Webhook pode ser enviado sem conversa
        webhook_url = action_params[0]
        if webhook_url.present?
          WebhookJob.perform_later(webhook_url, contact.webhook_data.merge(event: "contact_#{rule.event_name.split('_').last}"))
        end
      # Adicione outras ações que não precisam de conversa aqui
      end
    end
  end
end
