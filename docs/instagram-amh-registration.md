# Instagram AMH — cadastro e associação (etapa 6)

19/10/2026. Código preparado sobre o PR9 de links; sem implantação ou envio.

`POST /internal/instagram-amh/associate` reutiliza HMAC de serviço, corpo exato,
nonce, janela60s, Redis compartilhado e limite30/minuto do resolvedor. O limite
Rack1KB também cobre esta rota. Nenhum token administrativo ou cookie de login
Instagram é transferido ao site.

Payload fechado: `attribution_id`, `request_id`, `material`, `version_id`,
`graph_digest`, `email_hash` (SHA256 do e-mail normalizado) e `rate_key`. Link
válido, não revogado, material e versão congelada são revalidados sob row lock.
Resposta privada contém somente `assertion`, nunca contato, pedido anterior ou
código curto. Logs filtram os novos campos sensíveis.

Para associar, a emissão QA deve incluir `event.inbound_event_id`, UUID do evento
persistido pelo receptor autenticado. Links antigos sem referência continuam
resolvíveis, mas não concedem associação. A identidade vem do contrato cifrado,
com checagem da inbox protegida, conta/app, comentário, ad/mídia, palavra-chave,
exclusão de eco/spam/conta própria. Não procurar perfil por arroba, e-mail,
cookie, IP ou campo oculto; não escolher um evento por aproximação.

A asserção é JSON em base64url com HMAC-SHA256, v1/modoQA. Contém identidade e
referências técnicas necessárias ao consumidor; é **somente servidor**, não é
JWT/login nem resposta pública do formulário. Congela request/material, hash de
e-mail, evento mínimo, versão e prazo. Não inclui texto do comentário. Retries
iguais produzem a mesma asserção; duas inscrições podem usar o link encaminhado,
mas conflitos no Mautic são registrados sem reatribuir cadastros completos.

## Configuração e limites

Exige `INSTAGRAM_AMH_LINK_QA_ENABLED=true`,
`INSTAGRAM_AMH_ASSOCIATION_QA_ENABLED=true` e segredo dedicado32+bytes
`INSTAGRAM_AMH_ASSOCIATION_SECRET`. O Mautic recebe o mesmo segredo via secret
privado `instagram_amh_association_secret`; o site não recebe essa chave.
Flags ausentes/false nesta entrega. Não foi provisionado secret, evento, link,
cadastro, inscrição Meta, worker ou agendamento real.

Nenhuma migração nova. A asserção autoriza a associação quando emitida durante a
submissão; revogação/expiração anterior à autorização a impedem. Pedidos já
aceitos conservam seu snapshot durável e não são apagados por revogação posterior.
A fila e o Mautic validam prazo contra a data da captura, permitindo retry após
vencimento sem transformar uma nova captura expirada em válida.

A automação ainda é QA/inerte. Esta etapa não implementa executor comentário→DM,
ativação comercial ou PDF no obrigado. Etapa7 permanece separada.

## Validação

78 testes de segurança/regressão Ruby no banco local isolado, WebMock sem rede;
incluem corpo/HMAC/replay/flags, inbox/evento, material/versão, expiração e
revogação. RuboCop e `git diff --check`. Contraparte site testa as duas rotas e
fila durável; Mautic testa contrato nativo/reconciliação e ponte do worker em
runtime7.2.1 descartável. Sem evidência nova de evento Meta real.
