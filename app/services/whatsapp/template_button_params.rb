# frozen_string_literal: true

# Splits a template's processed_params into body parameters and button components.
#
# Meta numbers a URL button's {{n}} per button, not with the body, so the frontend
# names it `button_<index>_<n>`: the two scopes never collide in the flat params hash.
module Whatsapp::TemplateButtonParams
  BUTTON_KEY = /\Abutton_(\d+)_(\d+)\z/

  module_function

  # @param processed_params [Hash, nil]
  # @return [Array(Hash, Array<Hash>)] [body_params, button_components]
  def split(processed_params)
    return [{}, []] unless processed_params.is_a?(Hash)

    body = {}
    buttons = Hash.new { |h, k| h[k] = {} }
    processed_params.each do |key, value|
      match = BUTTON_KEY.match(key.to_s)
      if match
        buttons[match[1].to_i][match[2].to_i] = value
      else
        body[key] = value
      end
    end

    [body, button_components(buttons)]
  end

  # Meta's shape: one component per button, parameters in {{n}} order.
  def button_components(buttons)
    buttons.keys.sort.map do |index|
      {
        type: 'button',
        sub_type: 'url',
        index: index.to_s,
        parameters: buttons[index].keys.sort.map { |n| { type: 'text', text: buttons[index][n].to_s } }
      }
    end
  end
end
