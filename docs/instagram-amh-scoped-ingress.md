# Instagram AMH: scoped connection and durable reception

Prepared and tested locally; deployment and real-account validation remain pending.

Configure the same values on web and every worker: `INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID`, `INSTAGRAM_AMH_APP_ID` (must match the configured Instagram app), and `INSTAGRAM_AMH_RESERVED_INBOX_ID` (must belong to `INSTAGRAM_AMH_INBOX_IDS`). Keep `INSTAGRAM_AMH_RECEPTION_ENABLED=false` and `INSTAGRAM_AMH_INGRESS_ENABLED=false` during provisioning.

OAuth for this account binds the reserved inbox under a PostgreSQL advisory transaction lock. Conflicting bindings fail. Model callbacks do not subscribe the managed account. Existing accounts retain their subscription behavior. Subscription must be verified and performed separately for this account after the receiver is deployed and validated; do not replace the global callback or another account's connection.

Apply the new migration after the approved backup and restore validation workflow. The receiver verifies the raw-body HMAC before accepting scoped events. Enable both reception gates only after the correct binding exists. A paused receiver or persistence failure returns 503 so the provider can retry. Signed accepted batches are committed atomically before acknowledgement; the unique event key deduplicates retries. Other account entries continue through the existing receiver.

The ledger stores encrypted normalized metadata and bounded comment text, without DM bodies or raw payloads. Preserve the Rails key-generation secrets across deploys and restores to retain decryption. This stage creates no contacts, conversations, automated replies, read receipts or Mautic consumer. Scoped automated outbound remains blocked independently of reception. Spam flags, self activity and technical events do not become pending identities.

Rollback: pause both gates first; retain the ledger and reserved inbox outbound protection. Do not drop accepted events or revert to an unprotected OAuth callback for the managed account. Request logs redact webhook entries and OAuth codes/state.

Validation: 47 isolated PostgreSQL examples cover scoped OAuth binding, legacy subscriptions, signature rejection, encrypted persistence, duplicate delivery, mixed batches, HTTP integration, pause, failed-batch rollback, spam exclusion and existing outbound protections. These tests do not constitute a real Meta event or a production deployment.

Review regressions: query-supplied entries are rejected before legacy routing, oversized bodies are rejected before JSON parsing, and comment entry timestamps accept seconds or milliseconds.
