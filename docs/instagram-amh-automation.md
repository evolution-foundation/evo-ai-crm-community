# Instagram comment automations

The product editor replaces the simulation canvas with a guided publication → keyword alternatives → material/message → controlled test/activation flow. Frozen graphs remain the canonical contract; drafts do not change a running version.

## Execution

`AmhIngress` persists signed events before enqueueing `AmhDispatchJob`. Delivery uses a separate transport scoped to `recipient.comment_id` on Instagram Login, one message, URL in text. General campaign/journey transports remain blocked for the reserved inbox. Instagram Live is excluded.

`AmhExecutor` checks the bound inbox, app, professional account, token expiry, keyword, publication/ad, comment timestamp, active version and optional test identity. A transaction advisory lock serializes rule ambiguity checks and the unique per-inbound-event reservation. Only activated rules participate. Conflicting eligible rules stop the send. New commercial activation never replays older comments. Explicit controlled tests can select a persisted comment still inside seven days.

A `sending` reservation commits before the network call. Accepted, failed and uncertain outcomes are terminal: neither job retries nor repeated requests send again. A crash after reservation is deliberately left for reconciliation. Receipts are encrypted; the API exposes only operational IDs/states/timestamps. Provider acceptance is not proof of delivery or reading. No public reply, like or follow-up is sent.

## Configuration and rollout

Run migration `20261020160000` before publishing the API/worker. New gates default off. Set the same configuration on web and worker:

- `INSTAGRAM_AMH_EXECUTION_ENABLED=true`: dedicated comment executor only.
- `INSTAGRAM_AMH_LINK_QA_ENABLED=true`: existing signed short-link resolution gate.
- `INSTAGRAM_AMH_TEST_IGSIDS`: private comma-separated allowlist of account-scoped IDs, confirmed against the authorized test profile. Never infer from a browser or input username, commit the allowlist, or include it in public evidence.
- Existing association and instant-access gates must be enabled in the compatible CRM/site/ingress/worker/Mautic layers for end-to-end delivery. Preserve existing HMAC secrets and suppression rules.

Existing proofs remain paused after migration. Publish a frozen configuration, switch it to `test`, select an authorized received comment and send one private test reply. Commercial activation requires an accepted receipt for that exact proof/version. Pause clears the active version and is checked again immediately before transport. Operational gates can stop every dedicated send without opening the general automation safety gate.

`GET /api/v1/instagram_amh_proofs/catalog` lists connected account media and recently observed ad-only media without comment/profile content. API errors are visible instead of fabricating an empty inventory. Manual numeric media/ad IDs are an advanced fallback.

Member endpoints: `activate` (audience: paused/test/active with lock_version and version_id), `test_reply` (persisted event_id), `deliveries` (latest 50). Collection `test_events` returns comments only for allowlisted identities. Permissions reuse journeys.read and journeys.toggle_active. Draft naming supports update through the existing endpoint.

## Verification

Isolated PostgreSQL database `instagram_amh_safety_test`; WebMock disallows actual network access. Executor tests cover encrypted receipts, comment-scoped transport, duplicate requests, timeouts, wrong recipient, expired/live/DM/mismatching events, rule ambiguity, operational pause, activation revision and proof of controlled acceptance. Existing ingress, registration, short-link and safety suites remain applicable. Remote rollout and real Meta acceptance must be recorded separately from these local tests.

Private replies contract: [Meta documentation](https://developers.facebook.com/documentation/business-messaging/instagram-messaging/features/private-replies), existing API version v23.0. The official site rate-limited this session; real provider validation remains part of rollout.

## Confirmation required, 20 October product correction

Current execution requires `reply.confirmationRequired=true`. The first reply is only `openingText` plus the `Pode enviar` quick reply. It carries a purpose-bound, seven-day signed delivery token and no material URL. A comment cannot issue a short link. Historical direct-response graphs remain readable/simulatable but cannot be activated or dispatched.

The signed Meta receiver persists only the allowlisted quick-reply/postback payload, not the DM body. Plain text matching the button title is insufficient. The same identity/account/app/inbox, immutable version, active audience, operational gates, prompt receipt/expiry and a fresh inbound 24-hour window are checked again before delivery. A callback that arrives before the prompt receipt is saved has a bounded, pre-send retry. The link is issued only when the confirmed delivery is reserved durably. The material uses a button template with one `web_url`, `buttonLabel` and URL-free text, preventing a repeated raw link in the message.

Migration `20261020210000` adds separate invitation receipt/state, expiry and a unique confirmation-event reference. Prompt acceptance alone cannot authorize commercial activation: the exact version requires an accepted material delivery with a persisted confirmation event. Pause or version replacement invalidates pending confirmations. Neither an uncertain prompt nor an uncertain material response is retried automatically. No fallback can bypass confirmation when the provider rejects the initial interactive message.

This replaces the previous comment → direct material behavior following Ricardo's explicit correction. A new controlled comment and actual button tap are required for real Meta validation; the comment consumed by the historical direct test must not be replayed or fabricated.
