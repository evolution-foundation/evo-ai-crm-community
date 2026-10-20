# frozen_string_literal: true

# Persisted graph is the simulator input. No HTTP/queue/channel dependencies.
class Instagram::AmhVisualEngine
  STAGES = %w[comment scope keyword material reply result].freeze
  FIXTURES = %w[eligible negative scope_mismatch timeout repeated expired conflict missing_material].freeze
  MATERIALS = %w[amh amh-consultorio].freeze
  STOP = {
    'scope_mismatch' => ['scope', 'rejected', 'Conta/anúncio/publicação não corresponde'],
    'timeout' => ['reply', 'uncertain', 'Timeout simulado; reconciliar antes de repetir'],
    'repeated' => ['comment', 'skipped', 'Comentário repetido; recibo anterior preservado'],
    'expired' => ['reply', 'blocked', 'Janela da resposta privada expirada'],
    'conflict' => ['keyword', 'conflict', 'Múltiplas regras elegíveis; nenhuma escolhida'],
    'missing_material' => ['material', 'failed', 'Material sem mapeamento; sem link emitido']
  }.freeze
  class Invalid < StandardError; end

  def self.require_valid!(condition, message)
    raise Invalid, message unless condition
  end

  def self.validate!(graph)
    require_valid!(graph.is_a?(Hash) && graph.keys.sort == %w[edges nodes], 'Grafo inválido')
    require_valid!(JSON.generate(graph).bytesize <= 20_000, 'Grafo excede limite')
    validate_nodes!(graph['nodes'])
    validate_edges!(graph['edges'])
    validate_parameters!(graph['nodes'].to_h { |n| [n['id'], n['data']] })
    graph
  end

  def self.validate_nodes!(nodes)
    require_valid!(nodes.is_a?(Array) && nodes.size == 6 && nodes.all?(Hash), 'Seis nós são obrigatórios')
    require_valid!(nodes.pluck('id').sort == STAGES.sort, 'IDs dos nós devem ser únicos')
    nodes.each { |node| validate_node!(node) }
  rescue ArgumentError
    raise Invalid, 'IDs dos nós inválidos'
  end

  def self.validate_node!(node)
    require_valid!(node['type'] == node['id'] && node['data'].is_a?(Hash), 'Tipo ou parâmetros inválidos')
    position = node['position']
    require_valid!(position.is_a?(Hash), 'Posição inválida')
    require_valid!(position.values_at('x', 'y').all? { |v| v.is_a?(Numeric) && v.finite? }, 'Posição inválida')
  end

  def self.validate_edges!(edges)
    require_valid!(edges.is_a?(Array) && edges.size == 5 && edges.all?(Hash), 'Cinco conexões são obrigatórias')
    STAGES.each_cons(2) do |source, target|
      require_valid!(edges.count { |e| e['source'] == source && e['target'] == target } == 1, "Conecte #{source} → #{target}")
    end
  end

  def self.validate_parameters!(data)
    require_valid!(%w[scope keyword material reply].all? { |id| data[id].is_a?(Hash) }, 'Configuração de nó inválida')
    scope = data['scope']
    require_valid!(valid_string?(scope['account'], 100), 'Informe a conta')
    require_valid!(valid_string?(scope['ad'], 100) || valid_string?(scope['media'], 100), 'Informe anúncio ou publicação')
    validate_keyword!(data['keyword'])
    require_valid!(MATERIALS.include?(data['material']['material']), 'Material não permitido')
    reply = data['reply']
    if reply['confirmationRequired'] == true
      require_valid!(safe_button_text?(reply['openingText'], 1000), 'Convite inválido; não inclua links antes da confirmação')
      require_valid!(safe_button_text?(reply['text'], 640), 'Mensagem inválida; o link será enviado apenas no botão')
      require_valid!(valid_string?(reply['buttonLabel'], 20), 'Use até 20 caracteres no botão do material')
    else
      require_valid!(valid_string?(reply['text'], 1000) && reply['text'].include?('{{link}}'), 'Prévia inválida; use {{link}}')
    end
  end

  def self.safe_button_text?(text, max_bytes)
    valid_string?(text, max_bytes) && text.bytesize <= max_bytes && !text.match?(/https?:|www\.|\{\{link\}\}/i)
  end

  def self.validate_keyword!(rule)
    require_valid!(rule.is_a?(Hash), 'Configuração de palavra-chave inválida')
    require_valid!(%w[word contains].include?(rule['mode']), 'Modo de palavra-chave inválido')
    require_valid!([true, false].include?(rule['ignoreCase']) && [true, false].include?(rule['ignoreAccents']), 'Normalização inválida')
    keywords = rule['keywords']
    require_valid!(keywords.is_a?(Array) && keywords.size.between?(1, 10), 'Use de 1 a 10 palavras-chave')
    require_valid!(keywords.all? { |k| valid_string?(k, 60) }, 'Palavra-chave inválida')
  end

  def self.valid_string?(value, max)
    value.is_a?(String) && !value.strip.empty? && value.length <= max
  end

  def self.validate_text!(text)
    require_valid!(text.nil? || (text.is_a?(String) && text.length <= 200), 'Texto de teste inválido (máximo 200 caracteres)')
  end

  def self.normalize(text, rule)
    value = rule['ignoreAccents'] ? text.unicode_normalize(:nfd).gsub(/\p{Mn}/, '') : text
    rule['ignoreCase'] ? value.downcase : value
  end

  def self.matches?(text, rule)
    normalized = normalize(text, rule)
    rule['keywords'].any? do |keyword|
      needle = normalize(keyword.strip, rule)
      if rule['mode'] == 'contains'
        normalized.include?(needle)
      else
        /(?<![\p{L}\p{N}_])#{Regexp.escape(needle)}(?![\p{L}\p{N}_])/u.match?(normalized)
      end
    end
  end

  def self.simulate(graph, fixture:, now: Time.current, text: nil)
    validate!(graph)
    validate_text!(text)
    require_valid!(FIXTURES.include?(fixture), 'Fixture desconhecida')
    data = graph['nodes'].to_h { |n| [n['id'], n['data']] }
    text = effective_text(graph, fixture, text)
    trace = build_trace(graph, data, fixture, text, now)
    result_metadata(data, text).merge(fixture: fixture, trace: trace, outcome: trace.find do |t|
      t[:status] != 'passed'
    end&.fetch(:status) || 'simulated_accepted')
  end

  def self.effective_text(graph, fixture, text)
    return text unless text.nil?
    return '' if fixture == 'negative'

    graph['nodes'].find { |node| node['id'] == 'keyword' }.fetch('data').fetch('keywords').first
  end

  def self.result_metadata(data, text)
    { outbound_calls: 0, mautic_state: 'not_executed',
      preview: data['reply']['text'].gsub('{{link}}', 'https://co.agenciavetorial.com/QA000000'),
      requires_confirmation: data['reply']['confirmationRequired'] == true, opening_preview: data['reply']['openingText'],
      input_length: text.length,
      material: data['material']['material'], link_state: 'fixture_only_not_issued', contract: 'amh-visual-v1', mode: 'inert' }
  end

  def self.build_trace(graph, data, fixture, text, now)
    trace = []
    current = 'comment'
    stopped = false
    while current
      status, reason = stopped ? ['not_reached', 'Não executado após interrupção'] : node_result(current, data, fixture, text)
      stopped ||= status != 'passed'
      trace << { node: current, status: status, reason: reason, at: now.iso8601(6), attempts: status == 'not_reached' ? 0 : 1 }
      current = graph['edges'].find { |e| e['source'] == current }&.fetch('target')
    end
    trace
  end

  def self.node_result(node, data, fixture, text)
    return ['rejected', 'Nenhuma palavra-chave corresponde'] if node == 'keyword' && !matches?(text, data['keyword'])
    return STOP[fixture].drop(1) if STOP[fixture]&.first == node
    return ['passed', 'Transporte inerte aceitou a prévia; zero envio externo'] if node == 'reply'
    return ['passed', 'Simulação concluída; sincronização Mautic não executada'] if node == 'result'

    ['passed', 'Condição satisfeita']
  end
end
