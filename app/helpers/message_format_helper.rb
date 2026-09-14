module MessageFormatHelper
  # An attachment-only message carries content nil, and CommonMarker raises on it.
  def message_body_content(message_content)
    message_content.presence || ''
  end

  def render_message_content(message_content)
    EvolutionMarkdownRenderer.new(message_content).render_message
  end
end
