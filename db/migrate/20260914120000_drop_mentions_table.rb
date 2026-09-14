# CRM-579 — a menção nunca teve produtor neste fork.
#
# O único escritor da tabela era o `Conversations::UserMentionJob`, chamado pelo
# `Messages::MentionService`, cujo regex exigia id NUMÉRICO (`\d+`) enquanto
# `users.id` e `teams.id` são uuid desde a migration inicial. Nenhuma tela jamais
# emitiu a marcação `mention://`, em nenhum dos repos. A tabela é, por construção,
# vazia — e o `up` confere isso em vez de supor.
class DropMentionsTable < ActiveRecord::Migration[7.1]
  def up
    # Uma instalação que tenha importado linhas por fora (ex.: dump de um upstream
    # com `users.id` bigint) precisa ser vista, não atropelada em silêncio.
    if table_exists?(:mentions)
      sobrando = select_value('SELECT count(*) FROM mentions').to_i
      say "mentions: #{sobrando} linha(s) descartada(s)" if sobrando.positive?
    end

    drop_table :mentions, if_exists: true

    # `conversation_mention` era o valor 4 do enum `notifications.notification_type`.
    # Sai da lista de tipos junto com o resto; linha remanescente com esse valor
    # ficaria sem nome no enum. Pelo mesmo motivo acima, o normal é serem zero.
    orfas = execute('DELETE FROM notifications WHERE notification_type = 4').cmd_tuples
    say "notifications tipo 4 (conversation_mention): #{orfas} removida(s)" if orfas.positive?
  end

  def down
    create_table :mentions, id: :uuid, default: -> { 'gen_random_uuid()' }, force: :cascade do |t|
      t.uuid :user_id, null: false
      t.uuid :conversation_id, null: false
      t.datetime :mentioned_at, precision: nil, null: false
      t.datetime :created_at, precision: nil, null: false
      t.datetime :updated_at, precision: nil, null: false
      t.index [:conversation_id], name: 'index_mentions_on_conversation_id'
      t.index %i[user_id conversation_id], name: 'index_mentions_on_user_id_and_conversation_id', unique: true
      t.index [:user_id], name: 'index_mentions_on_user_id'
    end
  end
end
