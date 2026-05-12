class AutomationRules::ConditionValidationService
  ATTRIBUTE_MODEL = 'conversation_attribute'.freeze

  def initialize(rule)
    @rule = rule
    file = File.read('./lib/filters/filter_keys.yml')
    @filters = YAML.safe_load(file)

    @conversation_filters = @filters['conversations']
    @contact_filters = @filters['contacts']
    @message_filters = @filters['messages']
  end

  def perform
    @rule.conditions.each do |condition|
      return false unless valid_condition?(condition) && valid_query_operator?(condition)
    end

    true
  end

  private

  def valid_query_operator?(condition)
    query_operator = condition['query_operator']

    return true if query_operator.nil?
    return true if query_operator.empty?

    %w[AND OR].include?(query_operator.upcase)
  end

  def valid_condition?(condition)
    key = condition['attribute_key']

    conversation_filter = @conversation_filters[key]
    contact_filter = @contact_filters[key]
    message_filter = @message_filters[key]

    if conversation_filter || contact_filter || message_filter
      operation_valid?(condition, conversation_filter || contact_filter || message_filter)
    elsif pipeline_filter?(key)
      # Pipeline filters have special handling, consider them valid
      pipeline_operation_valid?(condition)
    else
      custom_attribute_present?(key, condition['custom_attribute_type'])
    end
  end

  def pipeline_filter?(attribute_key)
    %w[pipeline_id pipeline_stage_id].include?(attribute_key)
  end

  def pipeline_operation_valid?(condition)
    filter_operator = condition['filter_operator']

    # Pipeline filters support these operators. attribute_changed is included
    # because pipeline_stage_id transitions are dispatched by PipelineItem
    # callbacks with changed_attributes; without it the rule is rejected by
    # rule_valid? and silently dies before matching runs.
    %w[equal_to not_equal_to is_present is_not_present attribute_changed].include?(filter_operator)
  end

  def operation_valid?(condition, filter)
    filter_operator = condition['filter_operator']

    # attribute changed is a special case
    return true if filter_operator == 'attribute_changed'

    filter['filter_operators'].include?(filter_operator)
  end

  def custom_attribute_present?(attribute_key, attribute_model)
    attribute_model = attribute_model.presence || self.class::ATTRIBUTE_MODEL

    CustomAttributeDefinition.where(
      attribute_model: attribute_model
    ).find_by(attribute_key: attribute_key).present?
  end
end
