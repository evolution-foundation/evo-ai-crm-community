# Instagram comment automations

The product editor replaces the simulation canvas with a guided publication → keyword alternatives → material/message → controlled test/activation flow. Frozen graphs remain the canonical contract; drafts do not change a running version.

## Execution

`AmhIngress` persists signed events before enqueueing `AmhDispatchJob`. Delivery uses a separate transport scoped to `recipient.comment_id` on Instagram Login, one message, URL in text. General campaign/journey transports remain blocked for the reserved inbox. Instagram Live is excluded.

`AmhExecutor` checks the bound inbox, app, professional account, token expiry, keyword, publication/ad, comment timestamp, active version and optional test identity. A transaction advisory lock serializes rule ambiguity checks and the unique per-inbound-event reservation. Only activated rules participate. Conflicting eligible rules stop the send. New commercial activation never replays older comments. Explicit controlled tests can select a persisted comment still inside seven days.

A `sending` reservation commits before the network call. Accepted, failed and uncertain outcomes are terminal: neither job retries nor repeated requests send again. A crash after reservation is deliberately left for reconciliation. Receipts are encrypted; the API exposes only operational IDs/states/timestamps. Provider acceptance is not proof of delivery or reading. No public reply or follow-up is sent. Comment likes have an independent gated transport and receipt, described below.

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


## Comment likes (Facebook Login)

The invitation path reserves a separate `like_state=pending` only for new eligible
comments. Historical deliveries keep `not_requested`; deploying or supplying a
token never likes historical comments. The like runs after the invitation has its
own persisted outcome. A refusal, timeout or unavailable credential never blocks
the invitation, confirmation or material. Replays return the existing like receipt;
`sending`, accepted, refused, blocked and uncertain outcomes are not retried.

Meta documents `POST https://graph.facebook.com/v26.0/<IG_USER_ID>/likes` with a
JSON `comment_id`, a **Facebook Login user access token**, `instagram_basic` and
`instagram_manage_engagement`. An Instagram Login messaging token is insufficient.
Source checked on 20 October 2026:
[Meta User Likes](https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/user-likes).

Provision these protected runtime variables on web/worker only after the account
owner grants the new permission in Meta:

- `INSTAGRAM_AMH_LIKES_FACEBOOK_USER_TOKEN`: Facebook Login user token, not a Page token.
- `INSTAGRAM_AMH_LIKES_FACEBOOK_PAGE_ID`: Page linked to the managed professional account.
- `INSTAGRAM_AMH_LIKES_FACEBOOK_IG_USER_ID`: linked IG ID; it must match the managed
  account. Do not infer equivalence across login modes; confirm the binding.
- `INSTAGRAM_AMH_LIKES_ENABLED=true`: separate switch, default off.

Preflight reads granted scopes and the Page's `instagram_business_account`. A
mismatch or missing permission produces a blocked receipt and no like request.
The rule/version, test allowlist, expiry and gates are rechecked immediately before
the mutation. A database lock reserves at most 40 requests in five seconds across
workers, below Meta's 50-request burst limit. Excess work is blocked for review,
never automatically replayed. Provider error metadata is allowlisted/encrypted;
API snapshots expose only state, reason and acceptance time.

After provisioning, validate one new comment from the existing authorized test
identity, confirm the like in Instagram, click the invitation and check the material
receipt. Repeat the same event and prove zero additional outbound calls. Keep
commercial rules paused until the full test is accepted. Rollback: disable the
like gate; preserve reservations and receipts. Never clear a reservation to retry
an uncertain result. Existing blocked/historical rows are not backfilled.

Acceptance on 21 October 2026: a Facebook Login USER token issued by the SuperChat
app was provisioned separately from Direct credentials. Granted scopes and the
Page/Instagram binding were checked in the published runtime. One new comment from
the authorized test identity produced an accepted like and accepted material after
the real confirmation click. Commercial rules remain off; no historical backfill.

The initial SYSTEM_USER token did not include instagram_manage_engagement despite
selecting all permissions offered in its generator. Do not assume a system user's
control of an app grants that scope; inspect the token's actual grants. This is not
proof that every SYSTEM_USER token is unsupported. The validated path uses USER.

The long-lived token expires on 20 December 2026 at 10:46:36 UTC. Before expiry,
renew through the official Facebook Login flow, verify granted permissions and the
same account binding, and replace the protected value on both web and worker via
Portainer. Never overwrite the Instagram Login Direct token. If renewal fails,
disable only the like gate and preserve the existing invitation/material flow.
