# Instagram AMH — prova visual inerte (4V)

19/10/2026. Entrada no frontend: **Jornadas → Instagram AMH · editor e simulador**, rota `/journeys/instagram-amh`. Requer o PR do frontend correspondente, esta API e a migração `20261019180000`. Não implantado por esta entrega.

A prova reutiliza ReactFlow do Evo e a API/DB do CRM existente. Inventário read-only do Swarm confirmou frontend `main-9bc1b03`, CRM `vetorial-instagram-stage4-1dbae69`, nenhum Evo Flow e nenhuma variável `VITE_EVOFLOW_API_URL` no serviço frontend. A página publicada `/journeys` está acessível ao operador e vazia. Assim, canvas existente não equivale a motor publicado. Não se instala serviço, Typebot, timer ou IA para esta prova.

## Contrato

`/api/v1/instagram_amh_proofs`: GET lista (id/nome), POST cria; `/:id`: GET reabre, PATCH salva com `lock_version`; `/:id/publish`: POST congela rascunho com revisão esperada; `/:id/simulate`: POST recebe `version_id`, `fixture` e `text` sintético opcional, máximo 200 caracteres. Respostas usam envelope padrão CRM. GET/execução sem permissão retorna403; conflito de edição409; grafo inválido422. Permissões: journeys.read/create/update e toggle_active para publicar versão de simulação. Autenticação e isolamento seguem o CRM single-account, sem ampliar acessos.

Grafo v1 fechado: comment → scope → keyword → material → reply → result. Seis nós com posições editáveis; conexões podem ser removidas/recriadas e a API rejeita caminhos desconectados, ciclos ou atalhos. Sem construtor genérico nem nó de envio existente reutilizado inadvertidamente. O motor percorre as conexões do snapshot validado, não um diagrama paralelo.

Palavras-chave: 1–10 alternativas, palavra inteira (limites Unicode letras/números/underscore) ou contém; maiúsculas/acentos explicitamente configuráveis. Alternativas da mesma regra correspondem a uma única intenção. Múltiplas regras elegíveis são um conflito, sem prioridade implícita. Material limitado a `amh` e `amh-consultorio`. Copy exige `{{link}}`, substituído só por endereço de fixture não emitido. UI aceita texto sintético para ensaiar exemplos positivos/negativos; texto cru não é salvo no ledger, apenas digest/tamanho.

Fixtures: elegível, sem palavra-chave, escopo divergente, timeout, repetido, janela expirada, conflito e material ausente. Escopo/janela/conflito/ausência são falhas injetadas de fixture; não são consultas reais à Meta nem um inventário de outras regras. Adaptação ao webhook e resolução de anúncios reais pertencem ao próximo contrato de execução, não estão habilitadas aqui.

## Persistência e segurança

Tabela aditiva `instagram_amh_visual_proofs`: rascunho, versões congeladas e ledger de simulação, com trava otimista para edição e `with_lock` para publicação/execução. Versões guardam digest, operador, data e grafo; recibo guarda versão/digest e cada nó, estado, motivo, tentativas e data. Mesma versão+fixture+texto retorna o recibo existente, incluindo timeout incerto; não simula nova tentativa oculta. Limites:100 versões e800 recibos por prova; ao atingir, criar outra prova. Listagem retorna no máximo100 provas recentes, sem carregar grafos/ledgers.

Estado inicial/final **paused**, `outbound_enabled=false`. Não há endpoint de ativação, callback, job ou cliente HTTP de envio. Esta tabela não é AutomationRule/Journey executável e não é lida pelo listener inbound. Ledger de prova separado do ledger real cifrado `instagram_amh_inbound_events`; não consome nem forja eventos reais. Mautic aparece separadamente como `not_executed`. Gates de produtor/consumidor das etapas1–4 permanecem autoritativos e não são modificados. Link de fixture não é token emitido, recibo não significa DM entregue.

## Implantação posterior e rollback

Depois de revisão/autorização, reconciliar esta branch com a versão stage4 efetivamente publicada (código publicado fora da release Git; não substituir imagem inteira sem comparar). Backup e migração aditiva primeiro, backend e frontend compatíveis depois. A ausência da tabela não pode ser corrigida publicando só frontend. Não conectar esta prova ao listener para completar o deploy.

Rollback: retirar rota/link do frontend e voltar imagem do backend preservando a tabela, versões e recibos. Migração reversível ensaiada só em PostgreSQL isolado; não dropar evidências em produção. Nenhuma recepção, conexão, subscription, sincronização, credencial ou automação atual é alterada pela prova.

## Validação

Suite safety PostgreSQL local `instagram_amh_safety_test`, WebMock sem rede externa; engine com normalização, limites e grafo inválido, API com permissões, edição concorrente, reabertura, imutabilidade e dedup. Frontend com testes de salvamento, leitura sem edição e erro preservando rascunho, TypeScript/build e ESLint. Evidências visuais e resultado final no registro da etapa4V no acervo. Test harness de autenticação existe somente em arquivo temporário local, fora do Git/artefato de produção.
