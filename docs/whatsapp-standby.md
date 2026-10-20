# Passive WhatsApp standby (Vetorial)

Custom branch baseline: `vetorial/instagram-preview-upgrade` (`cd67891`). Do not merge this work into the upstream Evolution project or replace the custom baseline with the fork's upstream-tracking `main`.

The Cloud job splits every entry/change and message/echo/status item, preserving phone metadata. Nested `standby.message_echoes[].message` becomes an explicit outgoing observation. Ordinary Cloud messages, SMB echoes, history and Evolution payloads retain their entry paths. A channel row lock serializes concurrent workers; lookups are inbox-scoped. Empty arrays do not mask populated siblings. Invalid items are skipped; unknown/inactive channels and WABA mismatches get sanitized diagnostics; operational exceptions fail the job and are retried.

Observed messages use the existing imported source to suppress conversation/message automations, reply jobs, bot sync and template hooks. A dedicated ActionCable notification updates the UI. `whatsapp_observed` also blocks explicit SendReplyJob execution. Status updates on observations bypass automation publishers. Native incoming standby content/attachments reuse the Cloud parser, with optional contacts. Echo media IDs use the correct two-step Cloud download; external links remain metadata only to prevent SSRF; only Meta media IDs are downloaded. Templates combine supplied definition and parameters; incomplete definitions/flows receive an explicit readable fallback and retain auxiliary structure.

Status-only events never create a blank message. Pending statuses use Redis-backed Rails.cache for 24 hours; channel locking preserves monotonic transitions. Cache entries remain until TTL even after reconciliation, avoiding loss if the DB transaction rolls back. Production must retain its Redis cache configuration. Read/failed are terminal.

## One-way mirror

Disabled by default. Set only on CRM/worker using the same secret:

- `WHATSAPP_MIRROR_ENABLED=true`
- `WHATSAPP_MIRROR_URL=https://wapi.agenciavetorial.com/webhook/meta/mirror`
- `WHATSAPP_MIRROR_TOKEN`: independent random bearer token (32+ characters)

The allowlist is fixed to WABA `2257485551347138` and its three approved phone IDs. Cloud POST requests require a valid X-Hub-Signature-256 HMAC over the exact raw body, using WP_APP_SECRET (or WHATSAPP_APP_SECRET). Configure the actual signing app secret before rollout; missing secrets fail closed. A separate ActiveJob/Sidekiq job is enqueued before local processing. Enqueue failures are re-raised only after local persistence, so Sidekiq retries recover the mirror without duplicating CRM messages. Destination failure cannot roll back CRM persistence. Retries may repeat an envelope; Evolution deduplicates. Delivery requires `200 {"status":"persisted"}`. Twelve polynomial retries and a 24-hour retention bound prevent endless payload retention; exhausted jobs require operator recovery from the queue/backend. Disable mirroring before rollback; never delete channels to roll back, because their destruction can unsubscribe the entire WABA.

The callback, Meta subscriptions, conversation ownership and third-party service remain unchanged. No fixture should be posted to production. Tests use local PostgreSQL/Redis and block outbound HTTP. Command:

```sh
RAILS_ENV=test bundle exec rspec spec/services/whatsapp/standby_spec.rb spec/services/whatsapp/standby_security_spec.rb spec/services/whatsapp/standby_concurrency_spec.rb spec/services/whatsapp/incoming_message_base_service_spec.rb spec/services/whatsapp/phone_number_normalizer_spec.rb spec/services/whatsapp/incoming_message_evolution_service_spec.rb
```

Synthetic tests prove parser/storage behavior only. Real standby visibility and an echo from another application must be separately verified per channel.

Raw observed_payload is retained in storage but removed from all content-attribute egress audiences. Pending status retains failure diagnostics and contact identity for reconciliation without automation publishers.
