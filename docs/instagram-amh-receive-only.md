# Instagram AMH — etapa 1, recepção sem automações de saída

19/10/2026. Código preparado e validado localmente; **não implantado**. Base de revisão: `vetorial/instagram-preview-upgrade`, commit `5ba3a4f`, correspondente à referência da imagem inventariada. `main` não contém todas as customizações publicadas: este PR deve mirar essa branch de release para não remover mudanças anteriores. Merge/deploy não foram solicitados nesta entrega.

## Configuração e pausa

Antes de conectar qualquer nova recepção, configurar **o mesmo escopo no web e em todos os workers**:

```dotenv
# Lista explícita de UUIDs de inbox; preencher após conferir conta/canal.
INSTAGRAM_AMH_INBOX_IDS=<inbox-instagram-validada>
INSTAGRAM_AMH_RECEPTION_ENABLED=true
```

A lista vazia mantém a instalação existente intacta. Para uma inbox incluída, `outbound_enabled=false` é invariável nesta versão: não há flag para ativar DM, curtida ou resposta pública. Não inserir UUIDs de outros canais. Não usar automaticamente a inbox atual do inventário: a divergência entre conta Evo e actor dos anúncios ainda é gate da etapa 3.

A recepção DM existente segue funcionando com `RECEPTION_ENABLED=true`; `false` pausa a ingestão DM dessa frente antes de buscar perfil/gravar. Essa pausa não armazena eventos para replay: usar apenas em incidente, sabendo que a Meta pode exigir recuperação posterior. Não altera subscription, callback, token ou conexão. Aplicar configuração requer rollout coordenado do web e workers; variáveis de ambiente não se propagam entre processos em execução. Sem implantação completa, não declarar bloqueio efetivo em produção.

## Fronteiras protegidas

- Produtores: listeners de regras/contatos e bots, criação de respostas automáticas, delegação ao Bot Runtime, publicação EvoFlow e agendamento de entrega do Message.
- Consumidores: execução simples/canvas/contato, jobs de resposta/webhook/Bot Runtime/EvoFlow, segmentos atrasados, inatividade e serviços HTTP/N8n. Cada execução reavalia o escopo, inclusive retries antigos.
- Transporte: DM com Instagram Login e Messenger Login bloqueiam automações antes de acessar credenciais ou fazer POST; anexos também passam pelo mesmo controle.
- Respostas humanas, identificadas pelo sender `User` e sem proveniência de regra/campanha, continuam no transporte normal. Atributos `manual=true` não concedem exceção. Outros inboxes mantêm seu fluxo.
- Webhooks/macros/EvoFlow do escopo ficam pausados também: podem disparar integrações externas que enviariam mensagens. Contato ligado a várias inboxes tem seus gatilhos de contato pausados se alguma estiver no escopo; regras de conversa das demais inboxes permanecem ativas. Avaliar esse efeito antes de preencher a lista.

Ações futuras de curtida/resposta pública devem consultar `Instagram::AmhSafety.blocked_inbox?` antes de enfileirar **e** antes do transporte. Não há motor de comentários ou transporte dessas ações implementado nesta etapa. Os sete webhooks mortos inventariados não foram reprocessados.

Logs novos contêm somente fronteira (`inbox`, `contact`, `message`, `payload`), sem conteúdo, token ou pessoa. Eles permitem contar bloqueios sem chamar de envio aceito. Mensagens previamente enfileiradas são suprimidas sem replay automático; o status legado do registro não é prova de entrega. Para rollback, preservar o escopo e os gates até desligar a recepção e classificar filas: não remover a lista nem voltar a uma imagem sem proteção enquanto eventos entram.

## Mautic e limites da etapa

O inventário encontrou campanhas despublicadas e integração Instagram inativa, mas segmentos publicados. Nada disso foi alterado. Nenhum contato/segmento foi criado no Mautic nesta etapa; a sincronização dedicada, suas supressões e elegibilidade são contratos da etapa 2. O gate pausa os caminhos genéricos EvoFlow/webhook para contatos do escopo para impedir que essa recepção acione integrações antigas por inferência. Não usar o webhook genérico como sincronizador novo antes de validar os contratos Mautic.

O contato social pendente é persistido no Evo pelo builder existente, com e-mail vazio; não se afirma sincronização Mautic. Comentários elegíveis, mapa social canônico, outbox própria e migrações pertencem às etapas seguintes.

## Validação

`spec/safety/instagram/amh_safety_spec.rb` testa fronteiras reais da aplicação com colaboradores em memória, sem banco ou rede. `amh_safety_persistence_spec.rb` usa PostgreSQL/Redis locais descartáveis, bloqueio de rede WebMock e rollback; recusa qualquer banco cujo nome não seja `instagram_amh_safety_test`.

```sh
# Contratos sem persistência
RAILS_ENV=test SECRET_KEY_BASE=test bundle exec rspec spec/safety/instagram/amh_safety_spec.rb
# Persistência: fornecer exclusivamente conexões locais de QA
RAILS_ENV=test POSTGRES_DATABASE=instagram_amh_safety_test bundle exec rspec spec/safety/instagram
```

Cobertura: inbound persiste contato sem e-mail e mensagem, duplicata não duplica, resposta automática e retry não chamam Meta; bloqueio nos dois transportes; bots forçados/segmentos/inatividade; regras simples/canvas; webhooks serializados; Bot Runtime antigo; EvoFlow/contato; pausa da recepção; resposta humana e regra de outra inbox preservadas. Sem evento Meta real, saída real, migração, reconexão ou ativação.

Resultado local: 18 exemplos da etapa e 9 regressões existentes passaram (27 no total). RuboCop do serviço novo e dos testes da etapa sem infrações; arquivos legados têm dívida de lint preexistente e não foram reformatados em massa. Sintaxe Ruby e `git diff --check` conferidos.

Regressão ampliada EvoFlow: 93 exemplos, 89 passaram e 4 falharam. As mesmas quatro falhas foram reproduzidas carregando os quatro listeners originais de `5ba3a4f`: expectativas antigas de `additionalAttributes`, BigDecimal/Time e mensagem de log. Sem nova falha nessa comparação; a suíte ampliada não está globalmente verde.

Próxima etapa: 2, contratos e persistência da sincronização Mautic. Conexão real permanece na etapa 3, condicionada à conta correta e à implantação dos controles.
