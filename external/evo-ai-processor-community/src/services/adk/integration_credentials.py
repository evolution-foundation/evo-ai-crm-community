"""Resolves a consumer's credential from the integration vault, which holds the
secret encrypted and is pointed at by `credential_id`.

Two rules this module keeps: resolution is BY ID only, because precedence
between scopes has a single owner in the CRM resolver; and the inline value
stays the fallback, so an unresolvable reference only fails when there is
nothing to fall back to.

Free of heavy imports so it can be unit tested without the ADK stack; the
database and crypto handles are injected by the caller.
"""

import json
import logging
from typing import Any, Callable, Dict, Optional, Protocol, Tuple

logger = logging.getLogger(__name__)

KIND_OAUTH = "oauth"
VALUE_FORMAT_COMPOSITE = "composite"

# The composite envelope of story 2.1 keys the secret half as `password`.
COMPOSITE_SECRET_FIELD = "password"
COMPOSITE_PUBLIC_FIELD = "user"

# Which config field each provider reads its secret from. A name that does not
# match produces empty auth silently instead of an error, so every entry is
# asserted in the tests.
SECRET_FIELDS_BY_PROVIDER: Dict[str, Tuple[str, ...]] = {
    "dify": ("apiKey",),
    "flowise": ("apiKey",),
    "openai": ("apiKey",),
    # n8n splits the indivisible pair into the two fields it reads.
    "n8n": ("basicAuthUser", "basicAuthPass"),
    # Typebot authenticates with nothing at all. Registered explicitly so its
    # absence reads as a decision, not as an oversight someone should "fix".
    "typebot": (),
}


class CredentialVault(Protocol):
    """Reads an ACTIVE credential row, or nothing."""

    def fetch_active(self, credential_id: str) -> Optional[Dict[str, Any]]: ...


class DatabaseCredentialVault:
    """Reads the vault through the session the caller already has.

    Parameterized and scoped to one row; it does NOT open its own connection,
    unlike the raw-psycopg2 pattern that bypasses the ORM and the tenant GUC.
    """

    def __init__(self, db):
        self.db = db

    def fetch_active(self, credential_id: str) -> Optional[Dict[str, Any]]:
        from sqlalchemy import text

        try:
            row = self.db.execute(
                text(
                    "SELECT kind, value, value_format "
                    "FROM evo_core_integration_credentials "
                    "WHERE id = :id AND is_active = true LIMIT 1"
                ),
                {"id": str(credential_id)},
            ).fetchone()
        except Exception as exc:  # noqa: BLE001 - a vault outage falls back to inline, it does not crash the agent
            logger.error("Failed to read integration credential %s: %s", credential_id, exc)
            return None

        if not row:
            return None

        return {"kind": row[0], "value": row[1], "value_format": row[2]}


def apply_vault_credential(
    provider: str,
    config: Dict[str, Any],
    vault: CredentialVault,
    decrypt: Callable[[str], Optional[str]],
) -> Dict[str, Any]:
    """Returns a config whose secret fields come from the vault when a usable
    reference is present, and from the inline value otherwise.

    Raises only when a vault credential was asked for, could not be resolved,
    and there is nothing inline: an empty secret fails further away, with a
    worse message.
    """
    resolved = dict(config)

    secret_fields = SECRET_FIELDS_BY_PROVIDER.get(provider, ("apiKey",))
    if not secret_fields:
        return resolved

    credential_id = resolved.get("credential_id")
    if not credential_id:
        return resolved

    secret, reason = _fetch_secret(credential_id, vault, decrypt)
    if secret is None:
        if _has_inline_secret(resolved, secret_fields):
            logger.warning(
                "Integration credential %s could not be resolved (%s); falling back to the inline value",
                credential_id,
                reason,
            )
            return resolved
        # The reason travels into the message: "it is an oauth credential" and
        # "it does not exist" call for different fixes from whoever configured
        # the agent.
        raise ValueError(
            f"credential_id {credential_id} could not be resolved to a usable "
            f"integration credential ({reason}), and provider '{provider}' has "
            "no inline value to fall back to"
        )

    return _merge_secret(resolved, provider, secret_fields, secret, credential_id)


def resolve_credential_refs(
    values: Dict[str, Any],
    credential_refs: Dict[str, str],
    vault: CredentialVault,
    decrypt: Callable[[str], Optional[str]],
) -> Dict[str, Any]:
    """Overrides named entries with the secret each one references in the vault.

    A MAP because one credential is one secret: a tool with two auth headers
    references two, and a scalar could not say which header it replaces. Used
    for tool and MCP headers, and for official MCP env vars.

    An unresolvable reference falls back to the inline value, and raises when
    there is none.
    """
    resolved = dict(values)
    if not credential_refs:
        return resolved

    for name, credential_id in credential_refs.items():
        if not credential_id:
            continue

        secret, reason = _fetch_secret(credential_id, vault, decrypt)
        if secret is None:
            if resolved.get(name):
                logger.warning(
                    "Credential %s for %r could not be resolved (%s); using the inline value",
                    credential_id,
                    name,
                    reason,
                )
                continue
            raise ValueError(
                f"credential_id {credential_id} referenced by {name!r} could not be "
                f"resolved ({reason}), and there is no inline value to fall back to"
            )

        resolved[name] = secret

    return resolved


def _fetch_secret(
    credential_id: str,
    vault: CredentialVault,
    decrypt: Callable[[str], Optional[str]],
) -> Tuple[Optional[str], str]:
    """Returns the plaintext and, when there is none, why."""
    row = vault.fetch_active(credential_id)
    if not row:
        return None, "no active credential with that id"

    # An oauth row holds no value: the vault points at the store that owns the
    # token instead of copying it, and its value column is NULL by CHECK.
    if row.get("kind") == KIND_OAUTH:
        return None, "it is an oauth credential, which holds no value"

    try:
        plaintext = decrypt(row.get("value") or "")
    except Exception as exc:  # noqa: BLE001 - an undecryptable secret is a fallback case, not a crash
        logger.error("Failed to decrypt integration credential %s: %s", credential_id, exc)
        return None, "the stored value could not be decrypted"

    if not plaintext:
        return None, "the stored value could not be decrypted"

    return plaintext, ""


def _merge_secret(
    resolved: Dict[str, Any],
    provider: str,
    secret_fields: Tuple[str, ...],
    secret: str,
    credential_id: str,
) -> Dict[str, Any]:
    if len(secret_fields) == 1:
        resolved[secret_fields[0]] = secret
        return resolved

    # A pair: the vault stores it as one envelope, the provider reads two
    # fields.
    try:
        envelope = json.loads(secret)
        public = envelope[COMPOSITE_PUBLIC_FIELD]
        private = envelope[COMPOSITE_SECRET_FIELD]
    except (ValueError, KeyError, TypeError) as exc:
        logger.error(
            "Integration credential %s is not a usable composite envelope (%s); keeping the inline value",
            credential_id,
            exc,
        )
        return resolved

    public_field, private_field = secret_fields
    resolved[public_field] = public
    resolved[private_field] = private
    return resolved


def _has_inline_secret(config: Dict[str, Any], secret_fields: Tuple[str, ...]) -> bool:
    return any(config.get(field) for field in secret_fields)
