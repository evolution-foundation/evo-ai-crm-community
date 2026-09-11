# Changelog

All notable changes to this microservice will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v1.0.0-rc6] - 2026-07-04

Security and bug-fix release — closes the processor half of the EVO-1956 RBAC audit (third-party integration routes were reachable by any authenticated user), fixes OpenRouter key routing in LiteLLM, and eliminates the 500 on the session messages endpoint caused by non-JSON-serializable ADK payloads.

### Security

- **RBAC — integrations routes gated with `RequirePermission` (EVO-1956)** — the bulk integrations endpoint and the 12 third-party provider modules (GitHub, Google Calendar, Google Sheets, Notion, Linear, Monday, Atlassian, Asana, HubSpot, PayPal, Canva, Supabase) were fully reachable by any authenticated user, with no permission checks. 82 handlers are now gated by operation semantics (read / connect / update / create / disconnect), and a contract test locks in the invariants: every main-router endpoint must carry a gate with `resource=integrations` and an allow-listed action, while OAuth `callback_router` endpoints remain unauthenticated by design (browser redirects from external OAuth providers carry no CRM bearer token).

### Fixed

- **LiteLLM — OpenRouter key routed to the wrong vendor (EVO-1684)** (#15) — LiteLLM routes requests by the vendor embedded in the model id. When the API key's provider was OpenRouter but the agent model was e.g. `openai/gpt-4.1`, the request went to OpenAI with an OpenRouter key (`sk-or-v1-...`) and failed with `AuthenticationError`. Model ids are now normalized with the `openrouter/` prefix (idempotent, vendor preserved) and `api_base` is set to `https://openrouter.ai/api/v1` when the provider is OpenRouter. The `GeminiWithApiKey` path is untouched.
- **Sessions — 500 on `GET /sessions/{id}/messages` from `set`/`frozenset` in ADK payloads (EVO-1752)** (#16) — ADK event dicts could contain Python sets, which the default JSON encoder cannot serialize, aborting the whole response with a 500. Response helpers now go through `SafeJSONResponse` (making the API set-safe by construction), with regression coverage for the failing payload shapes.
- **`manage_conversation_labels` — guard against destructive replacement** — the tool reads current labels and merges before posting, because the CRM endpoint replaces (not appends) the label set. If the read came back empty due to a transient failure, the merge over an empty list would silently wipe existing labels (including the one keeping the AI eligible for the conversation). The add is now aborted when the read is empty and untrusted (non-200 status), instead of performing a destructive replace.
- **Chat token validation — `EvoAuthResponse` handling** — token validation now uses `EvoAuthResponse` directly instead of accessing a non-existent `.data` attribute.
- **Init — module aliasing** — ensures consistent module aliasing for registry access.

### Changed

- **CI — per-PR images for the review environment (EVO-1998)** — internal pull requests targeting `main`/`develop` now publish `:pr-<N>` and `:sha-<sha7>` images (amd64) for the review environment; multi-arch branch/tag builds are unchanged. The PR build job is gated to internal PRs (forks have no secrets).

### Notes for upgrade

- **RBAC**: after upgrading, roles need the `integrations.*` permissions to use the integrations endpoints and third-party providers; clients whose roles lack them will receive `403`. Review your role definitions before rolling out.

## [v1.0.0-rc5] - 2026-05-27

Hardening release — eliminates the processor's contribution to the fresh-install authentication failure. Also folds in the organization rename from `EvolutionAPI` to `evolution-foundation` across documentation.

### Fixed

- **Fresh-install boot — stop creating stub `users` table on `metadata.create_all`** — at startup the processor's SQLAlchemy `Base.metadata.create_all()` was emitting a `users(id integer)` stub that races with the auth service's authoritative `users` schema on a clean database. On a fresh install the processor occasionally won the race, leaving the auth service unable to insert/authenticate against its own table. Cross-service tables are now excluded from `create_all`; the processor only materializes tables it owns.

### Changed

- **Docs (org)** — GitHub URLs and references updated from `EvolutionAPI` to `evolution-foundation` to match the foundation rename. No code impact.

### Notes for upgrade

- **Fresh installs**: the `users` table stub conflict with `evo-auth-service-community` is resolved. No manual database cleanup is required on greenfield deployments; upgrading existing databases is a no-op (the auth service already owns the authoritative schema).

## [v1.0.0-rc4] - 2026-05-25

Point release — adds Typebot interactive button rendering. Other subsystems unchanged.

### Added

- **Typebot interactive buttons (#12)** — Typebot `choice` blocks now render as interactive button messages instead of plain text. Paired with corresponding changes in `evo-ai-crm-community` and `evo-ai-frontend-community`.

## [v1.0.0-rc3] - 2026-05-17

Integration release — adds native tools for the LLM agent (Knowledge Nexus search, manage_conversation_labels, link_product_to_pipeline_item), injection of the products catalog into the agent context, merging of integrations from the `agent_integrations` table into the agent config at runtime, and bug fixes in the Postgres handshake and chat handler binding. Also declares `EXTENSION_POINTS.md` as the public extension contract for the Enterprise edition.

### Added

- **EXTENSION_POINTS.md (EVO-1376)** (#9) — document with the extension points exposed by the processor to the Enterprise edition. Versioned contract, no new code.
- **`knowledge_nexus_search` — native tool** — agents gain access to semantic search on Nexus spaces directly from the prompt, without needing to configure a custom tool.
- **`manage_conversation_labels` — native tool** — list/add/remove labels on the conversation by the agent itself.
- **`link_product_to_pipeline_item` — native tool** — the agent can link catalog products to the active pipeline item.
- **Products catalog in the agent context** — products attached to the agent are injected into the prompt, letting the LLM have context about the offering.
- **Pipeline and labels usage hints in the prompt** — `pipeline_manipulation` and `manage_labels` gain structured hints in the system prompt to guide the LLM on when and how to use them.

### Changed

- **`llm-agent` — integrations merge** — integrations from the `agent_integrations` table are now merged into the agent config at runtime. Previously the config was static; now it reflects the latest state of integrations configured via the UI.
- **Docs** standardized for Evolution Foundation 2026 (README, LICENSE, NOTICE, TRADEMARKS).
- **Docs (org)** — GitHub URLs updated from `EvolutionAPI` to `evolution-foundation`.

### Fixed

- **DB — `sslmode` → `ssl` for asyncpg** — the asyncpg driver does not understand `sslmode` (a psycopg/libpq parameter). Connections with `sslmode=require` in the connection string failed silently; we now translate it to the asyncpg native parameter.
- **Chat handler — request param rebind** — fixes the binding of the `request` parameter in the chat handler that caused `NameError` on certain error paths.

## [v1.0.0-rc2] - 2026-05-05

### Fixed

- **Container startup**: invoke `alembic` and `uvicorn` via `python -m` instead of console scripts, preventing `sh -c` from interpreting the entrypoints incorrectly on some images. (#7)
- **Migration `26a14ac7025d`**: added `if_not_exists=True` on `op.create_table('evo_agent_processor_execution_metrics')`, making the migration safe to re-run in environments where the table has already been created by another service (shared database). (#7)

## [v1.0.0-rc1] - 2026-04-24

### Added

- First public release candidate of `evo-ai-processor-community`.

### Changed

- Refactored to remove the `account_id` parameter from internal services.
- Added multi-arch publish workflow to Docker Hub.
- Added build/publish workflow for `develop` images to staging.

### Fixed

- Resolved `UnboundLocalError` in `run_seeders.py`.
- Added `checkfirst` to `SQLAlchemy create_all` to avoid `DuplicateTableError`.
- Fixed middleware ordering and CORS / rate limiting conditions.
- `agent retrieval` migrated to async calls with refined error handling in `EvoAuthService`.
- Improved error handling in the response utility and the private messages tool.
- Added `PATCH` method to `EvoCrmClient` and support for `stage_name` in the pipeline manipulation tool.
- Removed the unused `CORS_ORIGINS` field from `settings`.
- **EVO-972**: serializes `set` in JSON responses and enriches the auth error surface. (#6)

### Security

- Removed the GCP service account key that leaked in previous commits. (#4)

## [0.1.0] - 2025-07-02

### Added

- JWT authentication via external service with FastAPI HTTPBearer integration
- Route-level protection: only sensitive endpoints require authentication
- Public endpoints (e.g. `/supported-formats`, `/health/status`) accessible without authentication
- Centralized configuration for external auth service via environment and settings
- Improved OpenAPI/Swagger experience with proper security scheme
- Error handling for unavailable or invalid authentication service
- English documentation and codebase

### Changed

- Refactored authentication logic to remove global dependencies and middleware
- Cleaned up project dependencies and removed unused packages
- Updated project structure and documentation to reflect microservice boundaries
- Improved logging and error messages for authentication and service health

### Fixed

- Fixed 401 errors on public endpoints by isolating JWT validation to protected routes only
- Fixed Swagger not sending Authorization header by using FastAPI security scheme

### Security

- All protected endpoints require valid JWT validated by external service
- No sensitive data exposed in logs or error messages

---

Older versions and future releases will be listed here.

[v1.0.0-rc6]: https://github.com/evolution-foundation/evo-ai-processor-community/compare/v1.0.0-rc5...v1.0.0-rc6
[v1.0.0-rc5]: https://github.com/evolution-foundation/evo-ai-processor-community/compare/v1.0.0-rc4...v1.0.0-rc5
[v1.0.0-rc4]: https://github.com/evolution-foundation/evo-ai-processor-community/compare/v1.0.0-rc3...v1.0.0-rc4
[v1.0.0-rc3]: https://github.com/evolution-foundation/evo-ai-processor-community/compare/v1.0.0-rc2...v1.0.0-rc3
[v1.0.0-rc2]: https://github.com/evolution-foundation/evo-ai-processor-community/compare/v1.0.0-rc1...v1.0.0-rc2
[v1.0.0-rc1]: https://github.com/evolution-foundation/evo-ai-processor-community/compare/0.1.0...v1.0.0-rc1
[0.1.0]: https://github.com/evolution-foundation/evo-ai-processor-community/releases/tag/0.1.0
