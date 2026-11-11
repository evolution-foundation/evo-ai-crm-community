# frozen_string_literal: true

namespace :conversas do
  desc 'Exporta mensagens dos clientes para CSV nos últimos N dias (default: 30)'
  task :exportar, [:dias, :arquivo_saida] => :environment do |_t, args|
    require 'csv'

    dias = (args[:dias] || 30).to_i
    arquivo_saida = args[:arquivo_saida] || "public/export_conversas_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv"
    data_limite = dias.days.ago

    puts "==> Buscando mensagens de clientes desde #{data_limite.strftime('%d/%m/%Y %H:%M')}..."

    # Filtra mensagens recebidas (incoming = 0), públicas e com conteúdo textual
    mensagens = Message.joins(:conversation)
                       .where(message_type: :incoming, private: false)
                       .where('messages.created_at >= ?', data_limite)
                       .where("messages.content IS NOT NULL AND messages.content != ''")
                       .order('conversations.display_id ASC, messages.created_at ASC')
                       .select(
                         'conversations.display_id AS ticket_id',
                         'conversations.cached_label_list AS etiquetas',
                         'messages.created_at AS data_envio',
                         'messages.content AS texto_mensagem',
                         'messages.sentiment AS sentimento'
                       )

    total = mensagens.count
    puts "==> Total de mensagens encontradas: #{total}"

    if total.zero?
      puts "Nenhuma mensagem encontrada para o período informado."
      next
    end

    FileUtils.mkdir_p(File.dirname(arquivo_saida))
    CSV.open(arquivo_saida, 'w', write_headers: true, headers: %w[ticket_id etiquetas data_envio mensagem sentimento]) do |csv|
      mensagens.find_each do |msg|
        csv << [
          msg.ticket_id,
          msg.etiquetas,
          msg.data_envio.strftime('%Y-%m-%d %H:%M:%S'),
          msg.texto_mensagem.to_s.squish,
          msg.sentimento
        ]
      end
    end

    puts "==> Exportação concluída com sucesso em: #{arquivo_saida}"
  end

  desc 'Analisa assuntos mais frequentes nas mensagens dos clientes (default: 30 dias)'
  task :analisar_assuntos, [:dias, :top_n] => :environment do |_t, args|
    dias = (args[:dias] || 30).to_i
    top_n = (args[:top_n] || 20).to_i
    data_limite = dias.days.ago

    stopwords = %w[
      a e o os as de da do das dos em no na nos nas por para com sem sobre
      um uma uns umas que se me te nos lhe lhes eu tu ele ela nos eles elas
      voce voces vc vcs pra pro este esta estes estas isso aquilo meu minha
      meus minhas seu sua seus suas nosso nossa nossos nossas que foi era seria
      ser ter estar ter havendo bom dia boa tarde noite ola ola oi olaa oii
      obrigado obrigada favor porfavor gostaria gostaria de poder pode podem
      tem como quero preciso gostaria ajuda atender atendimento obrigado
      sim nao mais muito pouco apenas ja ainda assim tao bem tudo nada
      aqui ai la quando onde como porque pq pq que quanto quantos
    ].to_set

    puts "\n========================================================"
    puts "  ANALISADOR DE ASSUNTOS FREQUENTES (Últimos #{dias} dias)"
    puts "========================================================\n"

    # 1. Análise de etiquetas registradas
    puts "--- TOP ETIQUETAS UTILIZADAS NOS ATENDIMENTOS ---"
    conversas_com_labels = Conversation.where('created_at >= ?', data_limite)
                                       .where("cached_label_list IS NOT NULL AND cached_label_list != ''")
                                       .pluck(:cached_label_list)

    label_counts = Hash.new(0)
    conversas_com_labels.each do |label_list|
      label_list.split(',').map(&:strip).each do |lbl|
        label_counts[lbl] += 1 unless lbl.empty?
      end
    end

    if label_counts.any?
      label_counts.sort_by { |_k, v| -v }.first(10).each_with_index do |(lbl, count), idx|
        puts format('%2d. %-30s (%d atendimentos)', idx + 1, lbl, count)
      end
    else
      puts "Nenhuma etiqueta registrada nas conversas do período."
    end

    # 2. Análise textual das falas dos clientes
    puts "\n--- TERMOS E ASSUNTOS MAIS CITADOS PELOS CLIENTES ---"
    textos = Message.where(message_type: :incoming, private: false)
                    .where('created_at >= ?', data_limite)
                    .where("content IS NOT NULL AND content != ''")
                    .pluck(:content)

    puts "Total de mensagens analisadas: #{textos.size}"
    if textos.empty?
      puts "Nenhuma mensagem encontrada."
      next
    end

    bigramas = Hash.new(0)
    trigramas = Hash.new(0)
    palavras_individuais = Hash.new(0)

    textos.each do |txt|
      limpo = txt.downcase.gsub(/[^a-záàâãéèêíïóôõöúçñ\s]/, ' ')
      tokens = limpo.split.reject { |t| t.length < 3 || stopwords.include?(t) }

      tokens.each { |tok| palavras_individuais[tok] += 1 }

      tokens.each_cons(2) do |par|
        bigramas[par.join(' ')] += 1
      end

      tokens.each_cons(3) do |trio|
        trigramas[trio.join(' ')] += 1
      end
    end

    puts "\n[Top Expressões / Bigramas Mais Comentados]:"
    bigramas.sort_by { |_k, v| -v }.first(top_n).each_with_index do |(termo, freq), idx|
      puts format('%2d. %-35s [%d ocorrências]', idx + 1, termo, freq)
    end

    puts "\n[Top Frases / Trigramas Mais Comentados]:"
    trigramas.sort_by { |_k, v| -v }.first(top_n).each_with_index do |(termo, freq), idx|
      puts format('%2d. %-40s [%d ocorrências]', idx + 1, termo, freq)
    end

    puts "\n========================================================\n"
  end
end

