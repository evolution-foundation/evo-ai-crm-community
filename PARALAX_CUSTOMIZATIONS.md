# Customizações da Paralax IA

Este repositório é um fork do `evo-ai-crm-community` (versão 1.1.0+). Abaixo está o registro das funcionalidades e melhorias customizadas que mantemos ativamente em relação à versão *upstream* da comunidade.

## 1. Status de "Digitando" via Evolution API
Embora o upstream ofereça integração com a Evolution API (`EvolutionService`), ele não conta com suporte a atualizações de *presence* (digitando/gravando áudio). 
**Nossa customização:** 
- Adicionamos o método `toggle_typing_status` no `Whatsapp::Providers::EvolutionService`.
- Mapeamos o status para a rota `/chat/sendPresence/` da Evolution API.
- Utilizamos um `delay` fixo de 60 segundos (60000ms) para manter o indicador "digitando" ativo durante o processamento do LLM ou para transbordos mais demorados.

## 2. Indicador Imediato de "Digitando" na Delegação
**Nossa customização:**
- No arquivo `app/services/bot_runtime/delegation_service.rb`, inserimos um disparo imediato do evento `conversation.typing_on` via `Rails.configuration.dispatcher.dispatch`.
- Isso garante que a interface (CRM) e o WhatsApp sinalizem atividade no exato momento em que o atendimento humano é delegado para o bot, cobrindo o gap de comunicação até que o *bot runtime* efetivamente acione o envio de mensagens.

## 3. Fallback de Credenciais IA (Resiliência)
**Nossa customização:**
- No arquivo `app/services/ai/credential_resolver.rb`, adicionamos o resgate explícito de exceções de banco de dados (`rescue ActiveRecord::StatementInvalid`, `PG::UndefinedColumn` e erros genéricos de query).
- Isso foi inserido para contornar problemas de *schema drift* e falta da tabela `evo_core_api_keys` ou suas colunas (`scope`), garantindo que o backend não responda com erro 500 caso as migrações upstream falhem parcialmente, utilizando o método de credenciais antigo (`api_key` de fallback).
