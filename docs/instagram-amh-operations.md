# Instagram AMH — acompanhamento operacional (etapa 8)

20/10/2026. `GET /api/v1/instagram_amh_proofs/operations` exige `journeys.read`,
usa envelope CRM e `Cache-Control: no-store`. Não altera regras, recepção,
sincronização, campanhas, links ou saídas. Não requer migração.

A projeção devolve até 50 provas recentes: conta/anúncio/publicação, material,
palavras-chave e prévia da última versão publicada para simulação; sem versão,
usa rascunho. `draft_changed` diferencia mudanças posteriores. Última simulação
mantém resultado, data e contador de chamadas externas; jamais vira evento real.
Todas as provas continuam inerentemente pausadas, sem endpoint de ativação.

O ledger de entrada é consultado apenas na inbox retornada por
`AmhConnection.bound_inbox!`. Retorna contagens por estado e até 50 recibos
recentes (ID técnico, estado e datas). Não decifra contratos, lê conversas,
expõe event_key, token ou identidade social. Falha de configuração retorna
`inbound.available=false`; falha de banco permanece erro HTTP, nunca fila vazia.
Recepção habilitada é configuração, não evidência de evento real recebido.

Contagens não representam pessoas canônicas: Mautic, conflitos, supressões e
eligibilidade de convite não são consultados. Botão de URL continua pendente de
validação real; prévia de texto não comprova payload homologado na Meta.

Frontend correspondente: Jornadas → Instagram AMH, busca/filtro, atualização
manual, falha/retry com data da última consulta e ativação indisponível com motivo.
Publicar versão no editor continua pausado. Implantar API compatível antes do
frontend; sem essa API, painel informa erro e o editor continua disponível.
Rollback: voltar frontend/backend anteriores, sem excluir provas ou recibos.

## Validação

85 testes safety Ruby em PostgreSQL `instagram_amh_safety_test`, WebMock sem rede;
HTTP/permissões, inbox isolada, projeção congelada/rascunho, privacidade e configuração
indisponível. RuboCop dos arquivos alterados aprovado. Executar com Ruby 3.4.4:

```sh
RAILS_ENV=test POSTGRES_DATABASE=instagram_amh_safety_test POSTGRES_USERNAME="$USER" SECRET_KEY_BASE=local-qa-inert bundle exec rspec spec/safety/instagram
```

8 testes React; TypeScript/build/lint; Chrome → API Rails real → PostgreSQL local
com fixtures sintéticas e autenticação/conta substituídas apenas em harness temporário,
sem bypass versionado. Larguras 320/375/390/1440, filtros, teclado, atualização,
sem overflow/erros e ativação bloqueada. Executar suite e harness em sequência:
alguns testes limpam tabelas de QA, portanto não compartilham banco simultaneamente.

Regressões do site em `c9faf3e`/PR52 (ainda aberto): check-instagram-access,
check-instagram-registration e check-instagram-amh aprovados. Nenhuma mudança no site
por esta etapa. Etapa 8 preparada para revisão; homologação operacional completa
depende da incorporação/rollout compatível de 7. Sem merge/deploy, envio controlado,
evento real Meta, navegador Instagram real ou ativação nesta entrega.
