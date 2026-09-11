"""Vault resolution for external agent integrations.

The runtime resolves a credential BY ID only. Precedence between scopes has a
single owner in the CRM (Ai::IntegrationCredentialResolver, story 2.2), and
duplicating it here would create a second truth about which credential wins.
"""

import importlib.util
import pathlib

import pytest

# Imported by path on purpose: `src.services.__init__` pulls in the whole ADK
# stack, so importing the module normally would drag google-adk and the database
# into a unit test that needs neither.
_MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[3]
    / "src"
    / "services"
    / "adk"
    / "integration_credentials.py"
)
_spec = importlib.util.spec_from_file_location("integration_credentials", _MODULE_PATH)
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)

SECRET_FIELDS_BY_PROVIDER = _module.SECRET_FIELDS_BY_PROVIDER
apply_vault_credential = _module.apply_vault_credential


class StubVault:
    """Stands in for the credentials table."""

    def __init__(self, rows=None):
        self.rows = rows or {}
        self.asked = []

    def fetch_active(self, credential_id):
        self.asked.append(credential_id)
        return self.rows.get(credential_id)


def vault_row(value, kind="static", value_format="scalar"):
    return {"kind": kind, "value": value, "value_format": value_format}


def test_dify_takes_the_secret_from_the_vault():
    vault = StubVault({"cred-1": vault_row("cipher")})
    config = {"credential_id": "cred-1", "apiUrl": "https://dify.example.com"}

    resolved = apply_vault_credential(
        "dify", config, vault=vault, decrypt=lambda _: "app-dify-9c1d"
    )

    assert resolved["apiKey"] == "app-dify-9c1d"
    assert resolved["apiUrl"] == "https://dify.example.com"


def test_openai_uses_the_same_secret_field():
    vault = StubVault({"cred-1": vault_row("cipher")})

    resolved = apply_vault_credential(
        "openai",
        {"credential_id": "cred-1", "assistantId": "asst_1"},
        vault=vault,
        decrypt=lambda _: "sk-openai",
    )

    assert resolved["apiKey"] == "sk-openai"
    assert resolved["assistantId"] == "asst_1"


def test_n8n_composite_becomes_the_basic_auth_pair():
    """The vault stores an indivisible pair; n8n reads two distinct fields.

    A mismatch here produces empty basic auth silently instead of an error,
    which is why the field names are asserted explicitly.
    """
    vault = StubVault({"cred-1": vault_row("cipher", value_format="composite")})

    resolved = apply_vault_credential(
        "n8n",
        {"credential_id": "cred-1", "webhookUrl": "https://n8n.example.com/hook"},
        vault=vault,
        decrypt=lambda _: '{"user": "admin", "password": "s3nha-f9b2"}',
    )

    assert resolved["basicAuthUser"] == "admin"
    assert resolved["basicAuthPass"] == "s3nha-f9b2"
    assert resolved["webhookUrl"] == "https://n8n.example.com/hook"


def test_typebot_has_no_secret_field_and_is_left_alone():
    vault = StubVault({"cred-1": vault_row("cipher")})
    config = {"credential_id": "cred-1", "url": "https://typebot.example.com"}

    resolved = apply_vault_credential(
        "typebot", config, vault=vault, decrypt=lambda _: "irrelevante"
    )

    assert resolved == config
    assert SECRET_FIELDS_BY_PROVIDER["typebot"] == ()
    assert vault.asked == [], "typebot has no credential, so the vault must not be consulted"


def test_without_a_reference_the_inline_value_is_untouched():
    """The fallback that makes this story non-blocking: an installation that has
    not migrated keeps working exactly as before."""
    vault = StubVault()
    config = {"apiUrl": "https://dify.example.com", "apiKey": "app-dify-inline"}

    resolved = apply_vault_credential(
        "dify", config, vault=vault, decrypt=lambda _: pytest.fail("must not decrypt")
    )

    assert resolved["apiKey"] == "app-dify-inline"
    assert vault.asked == [], "the vault was consulted without a reference"


def test_unresolvable_reference_falls_back_to_the_inline_value():
    vault = StubVault()  # the id resolves to nothing
    config = {
        "credential_id": "sumiu",
        "apiUrl": "https://dify.example.com",
        "apiKey": "app-dify-inline",
    }

    resolved = apply_vault_credential(
        "dify", config, vault=vault, decrypt=lambda _: "nunca"
    )

    assert resolved["apiKey"] == "app-dify-inline"


def test_unresolvable_reference_without_inline_raises_explicitly():
    """Never an empty key sent to the provider: the user asked for the vault and
    the vault could not answer, so the failure has to say so."""
    vault = StubVault()

    with pytest.raises(ValueError, match="credential"):
        apply_vault_credential(
            "dify",
            {"credential_id": "sumiu", "apiUrl": "https://dify.example.com"},
            vault=vault,
            decrypt=lambda _: "nunca",
        )


def test_oauth_reference_without_inline_raises_instead_of_authenticating_empty():
    vault = StubVault({"cred-1": vault_row(None, kind="oauth")})

    with pytest.raises(ValueError, match="oauth"):
        apply_vault_credential(
            "dify",
            {"credential_id": "cred-1", "apiUrl": "https://dify.example.com"},
            vault=vault,
            decrypt=lambda _: "nunca",
        )


def test_oauth_reference_falls_back_when_an_inline_value_exists():
    vault = StubVault({"cred-1": vault_row(None, kind="oauth")})

    resolved = apply_vault_credential(
        "dify",
        {"credential_id": "cred-1", "apiUrl": "https://x", "apiKey": "app-dify-inline"},
        vault=vault,
        decrypt=lambda _: "nunca",
    )

    assert resolved["apiKey"] == "app-dify-inline"


def test_undecryptable_value_falls_back_instead_of_sending_garbage():
    vault = StubVault({"cred-1": vault_row("lixo")})

    resolved = apply_vault_credential(
        "dify",
        {"credential_id": "cred-1", "apiUrl": "https://x", "apiKey": "app-dify-inline"},
        vault=vault,
        decrypt=lambda _: None,
    )

    assert resolved["apiKey"] == "app-dify-inline"


def test_flowise_without_any_secret_is_a_valid_state():
    """Flowise only adds the header when a key exists, so 'no secret' is not a
    configuration error the way it is for dify."""
    vault = StubVault()
    config = {"apiUrl": "https://flowise.example.com"}

    resolved = apply_vault_credential(
        "flowise", config, vault=vault, decrypt=lambda _: "nunca"
    )

    assert "apiKey" not in resolved


def test_the_original_config_is_never_mutated():
    vault = StubVault({"cred-1": vault_row("cipher")})
    config = {"credential_id": "cred-1", "apiUrl": "https://x"}

    apply_vault_credential("dify", config, vault=vault, decrypt=lambda _: "app-dify")

    assert "apiKey" not in config, "the caller's config was mutated in place"


def test_malformed_composite_envelope_falls_back():
    vault = StubVault({"cred-1": vault_row("cipher", value_format="composite")})

    resolved = apply_vault_credential(
        "n8n",
        {
            "credential_id": "cred-1",
            "webhookUrl": "https://x",
            "basicAuthUser": "admin",
            "basicAuthPass": "inline",
        },
        vault=vault,
        decrypt=lambda _: "nao-e-json",
    )

    assert resolved["basicAuthPass"] == "inline"
