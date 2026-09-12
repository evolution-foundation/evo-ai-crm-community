# frozen_string_literal: true

require 'rails_helper'

# CRM-607: `display_id` é alocado em Ruby por `maximum(:display_id) + 1`, que é um
# read-modify-write. Sob READ COMMITTED duas transações concorrentes leem o MESMO
# máximo (nenhuma enxerga a linha ainda não commitada da outra), escolhem o mesmo
# número, e todas menos uma morrem no índice único `index_conversations_on_display_id`.
# Medido antes do fix: de 8 criações simultâneas, 7 levantavam RecordNotUnique. No
# widget isso é 500 e a primeira mensagem do visitante some junto, porque
# Api::V1::Widget::ConversationsController#create grava conversa e mensagem na MESMA
# transação.
#
# Este spec precisa de concorrência DE VERDADE, e é por isso que abre mão das fixtures
# transacionais: com elas o Rails faz `pool.lock_thread = true`, todas as threads
# recebem a MESMA conexão e serializam sozinhas, então o spec passaria com e sem o fix.
# Mesmo molde de spec/lib/concurrent_index_migration_spec.rb.
RSpec.describe Conversation do
  self.use_transactional_tests = false

  # O pool do ambiente de teste é RAILS_MAX_THREADS (default 5) e a lane não seta a
  # env. Pedir mais conexões do que o pool tem trava em ConnectionTimeoutError e vira
  # flake, não prova: sobra uma para a thread principal.
  let(:concurrency) { [ActiveRecord::Base.connection_pool.size - 1, 4].min }

  let!(:channel) { Channel::WebWidget.create!(website_url: "https://crm607-#{SecureRandom.hex(4)}.example.com") }
  let!(:inbox) { Inbox.create!(name: "CRM607 #{SecureRandom.hex(3)}", channel: channel) }
  let!(:contact) { Contact.create!(name: 'CRM607', email: "crm607-#{SecureRandom.hex(6)}@example.com") }
  let!(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(6)) }

  # Sem fixtures transacionais as linhas COMMITAM e vazariam para os specs seguintes
  # do mesmo processo rspec (a lane roda dezenas de arquivos de uma vez).
  after do
    conversation_ids = described_class.where(inbox_id: inbox.id).pluck(:id)
    if conversation_ids.any?
      PipelineItem.where(conversation_id: conversation_ids).delete_all
      described_class.where(id: conversation_ids).delete_all
    end
    ContactInbox.where(inbox_id: inbox.id).delete_all
    Contact.where(id: contact.id).delete_all
    Inbox.where(id: inbox.id).delete_all
    Channel::WebWidget.where(id: channel.id).delete_all
  end

  # Todas as threads pegam conexão e só então são liberadas juntas. Sem essa barreira
  # elas partem em fila e o spec pode passar por acidente mesmo com o bug presente.
  def create_conversations_concurrently(count)
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(count)
    threads = Array.new(count) { |index| creator_thread(index, outcomes, ready, start) }

    # Com timeout: se uma thread nunca conseguir conexão ela morre em
    # ConnectionTimeoutError e nunca sinaliza. Um pop sem limite penduraria a lane
    # inteira até o timeout do runner; assim o join levanta o erro real.
    count.times { ready.pop(timeout: 30) }
    count.times { start << true }
    threads.each(&:join)

    outcomes.compact.partition { |outcome| outcome.is_a?(Integer) }
  end

  def creator_thread(index, outcomes, ready, start)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        start.pop
        outcomes[index] = create_one_conversation
      end
    end
  end

  # Devolve o display_id gravado, ou a descrição do erro que impediu a gravação.
  def create_one_conversation
    # A transação externa é o que o widget faz: conversa e mensagem no mesmo BEGIN.
    # É ela que decide por quanto tempo o lock de alocação fica retido.
    ActiveRecord::Base.transaction do
      described_class.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox).display_id
    end
  rescue StandardError => e
    "#{e.class}: #{e.message.lines.first.to_s.strip}"
  end

  describe 'alocação concorrente de display_id' do
    it 'dá um display_id distinto a cada criação simultânea, sem violar o índice único' do
      skip 'pool de conexões pequeno demais para provar concorrência' if concurrency < 2

      display_ids, failures = create_conversations_concurrently(concurrency)

      expect(failures).to be_empty
      expect(display_ids.size).to eq(concurrency)
      expect(display_ids.uniq.size).to eq(concurrency)
    end

    # O lock TEM que ser `pg_advisory_xact_lock`, nunca `pg_advisory_lock`. Com o de
    # sessão os DOIS exemplos falham; este existe porque o de cima falha sem acusar o
    # culpado. Medido com o de sessão e o pool default: a primeira thread grava e as
    # outras 3 ficam presas no lock que o COMMIT não liberou até bater o
    # statement_timeout de 14s, morrendo em QueryCanceled ("canceling statement due to
    # statement timeout"), erro que se lê como banco lento. Aqui basta uma criação e
    # 1,2s, e a conta de advisory locks retidos na conexão diz o que sobrou. E o
    # estrago não para num exemplo: o lock vazado viaja na conexão devolvida ao pool e
    # trava TODA criação de conversa seguinte do mesmo processo rspec (medido na ordem
    # do arquivo: o `create!` daqui morre dentro de ensure_display_id). Sob PgBouncer
    # em transaction mode (config/database.yml) é a criação de conversa em produção que
    # trava assim.
    it 'libera o lock de alocação no COMMIT, sem deixá-lo preso à conexão' do
      described_class.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      held_locks = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
      )

      expect(held_locks).to eq(0)
    end
  end
end
