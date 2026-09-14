module MessageFormatHelper
  # CRM-579: este helper também limpava a marcação `mention://` do conteúdo, e
  # isso saiu junto com a menção. O que sobra continua em método próprio porque é
  # load-bearing: mensagem de anexo sem texto chega com `content` nil, e o
  # renderizador de markdown abaixo não aceita nil.
  def message_body_content(message_content)
    message_content.presence || ''
  end

  def render_message_content(message_content)
    EvolutionMarkdownRenderer.new(message_content).render_message
  end
end
