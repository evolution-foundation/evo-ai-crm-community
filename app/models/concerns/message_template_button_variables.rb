# frozen_string_literal: true

# CRM-359: a dynamic URL button carries its own {{n}}, numbered by Meta per button,
# so it is declared as `button_<index>_<n>` next to the body variables — every picker
# that reads MessageTemplate#variables (journey, automation) asks for it, and the send
# splits it back off into the button component.
module MessageTemplateButtonVariables
  extend ActiveSupport::Concern

  private

  # `button_<index>_<n>` for every {{n}} in a URL button; index counts ALL buttons of
  # the BUTTONS component, the way Meta indexes them. Components arrive as a Hash keyed
  # by lower-cased type (the Meta sync, extract_components_hash) or as an Array (the
  # local editor), with string or symbol keys.
  def button_variable_names
    list = components.is_a?(Hash) ? components.values : Array(components)
    list.flat_map { |component| component_buttons(component).each_with_index.flat_map { |b, i| url_button_names(b, i) } }
  end

  def component_buttons(component)
    return [] unless component.is_a?(Hash) && hash_value(component, :type).to_s == 'BUTTONS'

    Array(hash_value(component, :buttons))
  end

  def url_button_names(button, index)
    return [] unless button.is_a?(Hash) && hash_value(button, :type).to_s == 'URL'

    hash_value(button, :url).to_s.scan(/\{\{(\d+)\}\}/).flatten.map { |n| "button_#{index}_#{n}" }
  end

  def hash_value(hash, key)
    hash[key.to_s] || hash[key.to_sym]
  end
end
