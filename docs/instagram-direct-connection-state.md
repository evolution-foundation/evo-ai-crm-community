# Direct Instagram connection state

The channel overview previously resolved every Instagram channel through Hub lifecycle metadata. A direct OAuth channel has no Hub status, so valid authorized accounts appeared as Unknown.

The resolver now distinguishes direct OAuth from Hub-managed connections. Stored account/token plus future expiry reports connected with `health_source=stored_flag`; missing credentials reports disconnected, expired tokens report error, and missing expiry remains unmonitored. A reauthorization flag still overrides every state. Hub lifecycle and all other channel providers retain their existing behavior.

This is stored authorization state, not a live availability check. Listing inboxes must never invoke the token accessor, refresh credentials, subscribe webhooks, or make provider requests. AMH reception and outbound gates are unchanged.

Validation: 64 isolated PostgreSQL examples passed, including direct-token expiry/boundary/missing credentials, Hub precedence, reauthorization, serialized UI fields/no token exposure and the AMH safety suite. RuboCop and git diff --check passed.

WhatsApp investigation: the production channel card still exposes six providers through Connect: Cloud, Evolution API, Evolution Go, Notificame, Z-API and Twilio. The provider-count badge is descriptive. Opening selection created no connection, changed no provider settings and sent no message. No frontend replacement is required to access this existing flow.
