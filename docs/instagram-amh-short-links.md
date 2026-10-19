# Instagram AMH — links curtos (etapa 5)

19/10/2026. Implementação preparada para QA, desabilitada por padrão. Sem listener,
timer, transporte Meta, associação de cadastro ou entrega de PDF. O editor 4V
continua sendo uma prova inerte; emitir um link de QA não o ativa.

## Contrato de emissão

`POST /api/v1/instagram_amh_links`, autenticado pelo CRM e `journeys.update`, recebe
`proof_id`, `version_id` congelada e `event`: strings `account`, `app`, `comment`,
`text`, mais `ad`/`media` opcionais. Somente esses campos são aceitos. Usar fixtures
sintéticas em ambiente isolado. Resposta201 contém `id`, `url`, `material`,
`expires_at`, `mode=qa`, `outbound_enabled=false`. A flag
`INSTAGRAM_AMH_LINK_QA_ENABLED=true` habilita explicitamente emissão/resolução.

O grafo salvo resolve conta, palavra-chave e material, nunca hidden fields do
formulário. `ad` presente exige igualdade exata e não cai em fallback de mídia;
mídia contraditória gera409. Sem `ad`, a mídia deve ser inequívoca. Outra versão
publicada de outra prova elegível gera409; mídia compartilhada sem ad também
gera409. Provas pausadas são consideradas apenas como inventário de QA, nunca
como regras operacionais. IDs reais do inventário da etapa0 só devem ser
transcritos em mapeamento revisado, sem inferir keyword/copy/ativação.

Seis bytes criptográficos → base64url sem padding → oito caracteres. URL fixa
`https://co.agenciavetorial.com/<codigo8>`,39 caracteres. Índices únicos de hash do
código e HMAC de conta/app/comentário asseguram dedup concorrente e retry. Colisão
gera novo código em savepoint; mesmo comentário sob outra versão exige revisão.
Snapshot cifrado congela evento sem texto bruto e grafo/edição técnica por digest.
Código recuperável fica cifrado para retries de QA; não existe outbox de envio nesta
etapa. Nunca registrar a URL emitida em Git, analytics, terminal gravado ou recibos
públicos. Sem nomes, arrobas ou conversas nos testes.

`DELETE /api/v1/instagram_amh_links/:id` revoga e apaga o payload cifrado. Validade
30dias, sem renovação implícita. `Instagram::AmhShortLink.compact_expired!` elimina
payloads vencidos; invocação operacional explícita, sem novo agendador. Tombstones
de hashes permanecem para impedir reutilização. Não executar limpeza por delete.

## Resolução de serviço

`POST /internal/instagram-amh/resolve`, sem privilégios CRM de usuário. Body JSON:
`code`, `rate_key` (HMAC do IP calculado no site). Headers `X-Amh-Timestamp` em
segundos, `X-Amh-Nonce`16bytes hex, `X-Amh-Signature`HMAC-SHA256 de
`timestamp.nonce.body_exato`. Segredo dedicado
`INSTAGRAM_AMH_LINK_SERVICE_SECRET`, mínimo32bytes. Janela60s; nonce com TTL120s
e limite30resoluções/minuto por chave em Redis compartilhado. Falha Redis fecha
o acesso. Não reutilizar API token administrativo para esta rota.

Resposta contém somente referência UUID forte de atribuição, material, destino
allowlisted, versão/digest, validade e modo QA. Código inválido, desconhecido,
expirado ou revogado retorna o mesmo404. Resolução não altera link/evento, não
cria contato nem conta clique humano. Sem endpoint público de consulta de PII.

## Implantação futura

Migração aditiva `20261019190000` no PostgreSQL existente do CRM. Backup e restore
antes de aplicar; backend antes do site. Esta entrega não aplica DDL em produção.
Rollback por flag false em ambos e imagem anterior, preservando tabela/recibos.
Nenhuma mudança de conta, assinatura, automação, permissão ou canal Meta.

O site usa cookie de QA cifrado, HttpOnly/Secure/SameSite=Lax, URL limpa e
allowlist fixa; o contrato de associação da etapa6 ainda não o consome. Antes de
ativar qualquer rota pública, revalidar proxy/CDN/log drains e redaction do caminho
curto (código no path não pode ser removido pelo logger Rails do resolvedor).
Os logs do CRM filtram `code`, `event`, `rate_key` e payload cifrado. A presença de
código pronto não comprova configuração de logs de terceiros nem homologação
real Meta. Nesta fase as flags permanecem ausentes/false em produção.

## Validação

`spec/safety/instagram`:67 testes em PostgreSQL isolado, WebMock sem rede, Redis
isolado por namespace/DB15. Inclui concorrência real entre conexões, colisão com
tombstone, revogação, replay HMAC, janela e rate limit, snapshot e conflitos.
RuboCop sem ocorrências. Migração down/up/down/up ensaiada em transação revertida.
O site mantém testes de contrato e roteamento, TypeScript, lint e build próprios.
