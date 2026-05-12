require 'json'

class AutomationRules::ConditionsFilterService < FilterService
  ATTRIBUTE_MODEL = 'contact_attribute'.freeze

  # Maps frontend attribute_key to the actual key present in changed_attributes.
  # Conversation/Contact dispatch previous_changes directly, so labels (via
  # acts-as-taggable) are stored as `label_list`. Without this alias the
  # attribute_changed filter would never match label transitions.
  ATTRIBUTE_KEY_ALIASES = {
    'labels' => 'label_list'
  }.freeze

  def initialize(rule, conversation = nil, options = {})
    super([], nil)
    @rule = rule
    @conversation = conversation

    # setup filters from json file
    file = File.read('./lib/filters/filter_keys.yml')
    @filters = YAML.safe_load(file)

    @conversation_filters = @filters['conversations']
    @contact_filters = @filters['contacts']
    @message_filters = @filters['messages']

    @options = options
    @changed_attributes = options[:changed_attributes]
  end

  def perform
    return false unless rule_valid?

    @attribute_changed_query_filter = []

    @rule.conditions.each_with_index do |query_hash, current_index|
      @attribute_changed_query_filter << query_hash and next if query_hash['filter_operator'] == 'attribute_changed'

      apply_filter(query_hash, current_index)
    end

    # Remove trailing query operators (and/or) that cause SQL syntax errors
    @query_string = @query_string.strip.gsub(/\s+(and|or)\s*$/i, '')

    records = base_relation.where(@query_string, @filter_values.with_indifferent_access)

    records = perform_attribute_changed_filter(records) if @attribute_changed_query_filter.any?

    records.any?
  rescue StandardError => e
    Rails.logger.error "[ConditionsFilterService] rule=#{@rule&.id} event=#{@rule&.event_name} error=#{e.class}: #{e.message} query=#{@query_string.inspect} filter_values=#{@filter_values.inspect}"
    EvolutionExceptionTracker.new(e).capture_exception
    false
  end

  def rule_valid?
    is_valid = AutomationRules::ConditionValidationService.new(@rule).perform
    Rails.logger.info "Automation rule condition validation failed for rule id: #{@rule.id}" unless is_valid
    @rule.authorization_error! unless is_valid

    is_valid
  end

  def filter_operation(query_hash, current_index)
    if query_hash[:filter_operator] == 'starts_with'
      @filter_values["value_#{current_index}"] = "#{string_filter_values(query_hash)}%"
      like_filter_string(query_hash[:filter_operator], current_index)
    else
      super
    end
  end

  def apply_filter(query_hash, current_index)
    filters = extract_filters(query_hash)
    @query_string += build_query_string(filters, query_hash, current_index)
  end

  # If attribute_changed type filter is present perform this against array
  def perform_attribute_changed_filter(records)
    @attribute_changed_records = []
    current_attribute_changed_record = base_relation
    filter_based_on_attribute_change(records, current_attribute_changed_record)

    @attribute_changed_records.uniq
  end

  # Loop through attribute_changed_query_filter
  def filter_based_on_attribute_change(records, current_attribute_changed_record)
    @attribute_changed_query_filter.each do |filter|
      @changed_attributes = @changed_attributes.with_indifferent_access
      backend_key = ATTRIBUTE_KEY_ALIASES.fetch(filter['attribute_key'], filter['attribute_key'])
      changed_attribute = @changed_attributes[backend_key].presence

      # Skip silently when the watched attribute did not change in this update.
      # Avoids NoMethodError on changed_attribute[0] which was being swallowed
      # by the rescue in #perform, masking real bugs.
      next unless changed_attribute.is_a?(Array) && changed_attribute.length >= 2

      if attribute_changed_match?(filter, changed_attribute)
        @attribute_changed_records = attribute_changed_filter_query(filter, records, current_attribute_changed_record)
      end
      current_attribute_changed_record = @attribute_changed_records
    end
  end

  def attribute_changed_match?(filter, changed_attribute)
    if filter['attribute_key'] == 'labels'
      labels_transition_match?(filter, changed_attribute)
    else
      scalar_transition_match?(filter, changed_attribute)
    end
  end

  # Mirrors the wildcard semantics of labels_transition_match?: an empty
  # `from` or `to` list means "any value on that side". Without this the
  # frontend can save `from: [], to: ['resolved']` (intent: any status ->
  # resolved) and Ruby's `Array.in?([])` is always false, so the rule never
  # fires.
  def scalar_transition_match?(filter, changed_attribute)
    from_values = Array(filter['values']['from'])
    to_values = Array(filter['values']['to'])

    from_match = from_values.empty? || changed_attribute[0].in?(from_values)
    to_match = to_values.empty? || changed_attribute[1].in?(to_values)

    from_match && to_match
  end

  # Labels are array-valued (label_list via acts-as-taggable). Match by diff:
  # `to` is satisfied when at least one of the requested labels was added in
  # this update; `from` is satisfied when at least one was removed. An empty
  # `to`/`from` acts as a wildcard for that direction.
  def labels_transition_match?(filter, changed_attribute)
    previous_labels = Array(changed_attribute[0])
    current_labels = Array(changed_attribute[1])
    from_titles = label_titles_from_ids(filter['values']['from'])
    to_titles = label_titles_from_ids(filter['values']['to'])

    added = current_labels - previous_labels
    removed = previous_labels - current_labels

    return false if to_titles.any? && !added.intersect?(to_titles)
    return false if from_titles.any? && !removed.intersect?(from_titles)

    true
  end

  def label_titles_from_ids(ids)
    return [] if ids.blank?

    Label.where(id: Array(ids)).pluck(:title)
  end

  # We intersect with the record if query_operator-AND is present and union if query_operator-OR is present
  def attribute_changed_filter_query(filter, records, current_attribute_changed_record)
    if filter['query_operator'] == 'AND'
      @attribute_changed_records + (current_attribute_changed_record & records)
    else
      @attribute_changed_records + (current_attribute_changed_record | records)
    end
  end

  def message_query_string(current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    attribute_key = 'processed_message_content' if attribute_key == 'content'

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'standard'
      if current_filter['data_type'] == 'text'
        " LOWER(messages.#{attribute_key}) #{filter_operator_value} #{query_operator} "
      else
        " messages.#{attribute_key} #{filter_operator_value} #{query_operator} "
      end
    end
  end

  # This will be used in future for contact automation rule
  def contact_query_string(current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    # Para labels, converte IDs para títulos
    if attribute_key == 'labels'
      label_ids = query_hash['values']
      label_titles = Label.where(id: label_ids).pluck(:title)
      query_hash = query_hash.merge('values' => label_titles)
    end

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'additional_attributes'
      " contacts.additional_attributes ->> '#{attribute_key}' #{filter_operator_value} #{query_operator} "
    when 'standard'
      if attribute_key == 'labels'
        " tags.name #{filter_operator_value} #{query_operator} "
      else
        " contacts.#{attribute_key} #{filter_operator_value} #{query_operator} "
      end
    end
  end

  def conversation_query_string(table_name, current_filter, query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']

    # Para labels, converte IDs para títulos
    if attribute_key == 'labels'
      label_ids = query_hash['values']
      label_titles = Label.where(id: label_ids).pluck(:title)
      query_hash = query_hash.merge('values' => label_titles)
    end

    filter_operator_value = filter_operation(query_hash, current_index)

    case current_filter['attribute_type']
    when 'additional_attributes'
      " #{table_name}.additional_attributes ->> '#{attribute_key}' #{filter_operator_value} #{query_operator} "
    when 'standard'
      if attribute_key == 'labels'
        " tags.name #{filter_operator_value} #{query_operator} "
      else
        " #{table_name}.#{attribute_key} #{filter_operator_value} #{query_operator} "
      end
    end
  end

  private

  def extract_filters(query_hash)
    {
      conversation: @conversation_filters[query_hash['attribute_key']],
      contact: @contact_filters[query_hash['attribute_key']],
      message: @message_filters[query_hash['attribute_key']]
    }
  end

  def build_query_string(filters, query_hash, current_index)
    if filters[:conversation]
      conversation_query_string('conversations', filters[:conversation], query_hash.with_indifferent_access, current_index)
    elsif filters[:contact]
      contact_query_string(filters[:contact], query_hash.with_indifferent_access, current_index)
    elsif filters[:message]
      message_query_string(filters[:message], query_hash.with_indifferent_access, current_index)
    elsif pipeline_filter?(query_hash['attribute_key'])
      pipeline_query_string(query_hash.with_indifferent_access, current_index)
    elsif custom_attribute(query_hash['attribute_key'], query_hash['custom_attribute_type'])
      custom_attribute_query(query_hash.with_indifferent_access, query_hash['custom_attribute_type'], current_index)
    else
      ''
    end
  end

  def pipeline_filter?(attribute_key)
    %w[pipeline_id pipeline_stage_id].include?(attribute_key)
  end

  def pipeline_query_string(query_hash, current_index)
    attribute_key = query_hash['attribute_key']
    query_operator = query_hash['query_operator']
    filter_operator_value = filter_operation(query_hash, current_index)

    " pipeline_items.#{attribute_key} #{filter_operator_value} #{query_operator} "
  end

  def base_relation
    records = Conversation.where(id: @conversation.id).joins(
      'LEFT OUTER JOIN contacts on conversations.contact_id = contacts.id'
    ).joins(
      'LEFT OUTER JOIN messages on messages.conversation_id = conversations.id'
    ).joins(
      'LEFT OUTER JOIN pipeline_items on pipeline_items.conversation_id = conversations.id'
    ).joins(
      'LEFT OUTER JOIN pipeline_stages on pipeline_stages.id = pipeline_items.pipeline_stage_id'
    ).joins(
      'LEFT OUTER JOIN pipelines on pipelines.id = pipeline_items.pipeline_id'
    )

    # Adiciona JOIN com tags se houver condições de labels
    if @rule.conditions.any? { |c| c['attribute_key'] == 'labels' }
      # Para conversas, usa taggings com taggable_type = 'Conversation'
      # Para contatos, usa taggings com taggable_type = 'Contact'
      if @rule.event_name.include?('contact')
        records = records.joins("LEFT OUTER JOIN taggings ON taggings.taggable_id = contacts.id AND taggings.taggable_type = 'Contact' AND taggings.context = 'labels'")
                         .joins('LEFT OUTER JOIN tags ON tags.id = taggings.tag_id')
      else
        records = records.joins("LEFT OUTER JOIN taggings ON taggings.taggable_id = conversations.id AND taggings.taggable_type = 'Conversation' AND taggings.context = 'labels'")
                         .joins('LEFT OUTER JOIN tags ON tags.id = taggings.tag_id')
      end
    end

    records = records.where(messages: { id: @options[:message].id }) if @options[:message].present?
    records
  end
end
