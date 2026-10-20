class Whatsapp::ObservedContent
  def self.render(message)
    return render_template(message) if message[:type] == 'template'

    interactive = message[:interactive] || message[:button] || {}
    [interactive.dig(:body, :text), interactive.dig(:button_reply, :title),
     interactive.dig(:list_reply, :title), interactive[:text]].compact.presence&.join("\n") ||
      'Mensagem interativa (conteúdo completo indisponível)'
  end

  def self.render_template(message)
    definition = message[:standby_template]
    body = body_component(definition)[:text]
    parameters = body_component(message[:template])[:parameters] || []
    rendered = substitute(body, parameters) if body.present?
    return rendered if rendered.present? && !rendered.match?(/\{\{.*?\}\}/)

    "Modelo #{message.dig(:template, :name)} (conteúdo completo indisponível)"
  end

  def self.body_component(definition)
    return {} unless definition.is_a?(Hash)

    Array(definition[:components]).find { |c| c[:type].to_s.downcase == 'body' } || {}
  end

  def self.substitute(body, parameters)
    parameters.each_with_index do |param, index|
      value = param[:text] || param.dig(:currency, :fallback_value) || param.dig(:date_time, :fallback_value)
      body = body.gsub("{{#{param[:parameter_name] || (index + 1)}}}", value.to_s) if value
    end
    body
  end
end
