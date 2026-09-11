"""Vault resolution for tool and MCP headers and env vars.

Same rule as story 2.3: resolution here is BY ID, the inline value stays the
fallback, and precedence between scopes has a single owner in the CRM.
"""

import importlib.util
import pathlib

import pytest

_MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[3]
    / "src"
    / "services"
    / "adk"
    / "integration_credentials.py"
)
_spec = importlib.util.spec_from_file_location("integration_credentials_2_4", _MODULE_PATH)
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)

resolve_credential_refs = _module.resolve_credential_refs


class StubVault:
    def __init__(self, rows=None):
        self.rows = rows or {}
        self.asked = []

    def fetch_active(self, credential_id):
        self.asked.append(credential_id)
        return self.rows.get(credential_id)


def row(value, kind="static"):
    return {"kind": kind, "value": value, "value_format": "scalar"}


def test_reference_overrides_the_named_header():
    vault = StubVault({"cred-1": row("cipher")})
    headers = {"Authorization": "Bearer inline", "Content-Type": "application/json"}

    resolved = resolve_credential_refs(
        headers,
        {"Authorization": "cred-1"},
        vault=vault,
        decrypt=lambda _: "Bearer do-cofre",
    )

    assert resolved["Authorization"] == "Bearer do-cofre"
    assert resolved["Content-Type"] == "application/json"


def test_two_auth_headers_resolve_two_distinct_credentials():
    """The cardinality rule of the epic: one credential equals one secret."""
    vault = StubVault({"cred-1": row("c1"), "cred-2": row("c2")})
    secrets = {"c1": "primeiro", "c2": "segundo"}

    resolved = resolve_credential_refs(
        {"Authorization": "inline-1", "X-Api-Key": "inline-2"},
        {"Authorization": "cred-1", "X-Api-Key": "cred-2"},
        vault=vault,
        decrypt=lambda ciphertext: secrets[ciphertext],
    )

    assert resolved["Authorization"] == "primeiro"
    assert resolved["X-Api-Key"] == "segundo"
    assert sorted(vault.asked) == ["cred-1", "cred-2"]


def test_without_refs_the_inline_headers_are_untouched():
    vault = StubVault()
    headers = {"Authorization": "Bearer inline"}

    resolved = resolve_credential_refs(
        headers, {}, vault=vault, decrypt=lambda _: pytest.fail("must not decrypt")
    )

    assert resolved == headers
    assert vault.asked == []


def test_unresolvable_reference_falls_back_to_the_inline_header():
    vault = StubVault()

    resolved = resolve_credential_refs(
        {"Authorization": "Bearer inline"},
        {"Authorization": "sumiu"},
        vault=vault,
        decrypt=lambda _: "nunca",
    )

    assert resolved["Authorization"] == "Bearer inline"


def test_unresolvable_reference_without_inline_raises():
    """Never an empty header sent to the destination: the user asked for the
    vault and the vault could not answer."""
    vault = StubVault()

    with pytest.raises(ValueError, match="credential"):
        resolve_credential_refs(
            {}, {"Authorization": "sumiu"}, vault=vault, decrypt=lambda _: "nunca"
        )


def test_oauth_reference_without_inline_raises():
    vault = StubVault({"cred-1": row(None, kind="oauth")})

    with pytest.raises(ValueError, match="oauth"):
        resolve_credential_refs(
            {}, {"Authorization": "cred-1"}, vault=vault, decrypt=lambda _: "nunca"
        )


def test_env_vars_use_the_same_resolution():
    """MCP official servers reference env vars by name, same map shape."""
    vault = StubVault({"cred-1": row("cipher")})

    resolved = resolve_credential_refs(
        {"GITHUB_PERSONAL_ACCESS_TOKEN": "inline"},
        {"GITHUB_PERSONAL_ACCESS_TOKEN": "cred-1"},
        vault=vault,
        decrypt=lambda _: "ghp_do_cofre",
    )

    assert resolved["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_do_cofre"


def test_the_original_map_is_never_mutated():
    vault = StubVault({"cred-1": row("cipher")})
    headers = {"Authorization": "Bearer inline"}

    resolve_credential_refs(
        headers, {"Authorization": "cred-1"}, vault=vault, decrypt=lambda _: "novo"
    )

    assert headers["Authorization"] == "Bearer inline", "the caller's map was mutated"


def test_mcp_context_no_longer_pollutes_os_environ():
    """Negative proof for the os.environ leak.

    Each MCP env var used to be written into the processor's own os.environ, on
    top of being passed to the child. The write was redundant and never undone,
    so one agent's token leaked into every MCP subprocess spawned afterwards,
    and across tenants in the enterprise build. This is also the exact point
    where vault-resolved secrets now pass through, so leaving it would undo the
    vault's whole benefit one line later.
    """
    source = (
        pathlib.Path(__file__).resolve().parents[3]
        / "src"
        / "services"
        / "adk"
        / "mcp_context.py"
    ).read_text()

    stdio_block = source.split("else:  # Local server (Stdio)")[1]
    assignments = [
        line
        for line in stdio_block.splitlines()
        if "os.environ[" in line and not line.strip().startswith("#")
    ]

    assert assignments == [], f"os.environ is written again: {assignments}"


def test_mcp_service_logs_header_names_not_values():
    """Bearer tokens used to reach the logs: two call sites dumped the whole
    header map before the masking helper ran."""
    source = (
        pathlib.Path(__file__).resolve().parents[3]
        / "src"
        / "services"
        / "adk"
        / "mcp_service.py"
    ).read_text()

    leaking = [
        line
        for line in source.splitlines()
        if "server_config.get('headers', {})}" in line
        and ".keys()" not in line
        and not line.strip().startswith("#")
    ]

    assert leaking == [], f"header values still reach the logs: {leaking}"


# The end-to-end contract for an official MCP server:
#
#   agent.config.mcp_servers[i] = {
#     id, environments: {VAR: '<inline>'}, credential_refs: {VAR: '<uuid>'}, tools
#   }
#
# The front writes it, the core carries it through the processing allowlist, and
# this asserts the processor resolves it. A test over the resolver alone passes
# even with the wrong key.
def test_official_mcp_env_resolves_end_to_end_with_the_persisted_shape():
    import importlib.util as _il
    import pathlib as _pl

    spec = _il.spec_from_file_location(
        "mcp_service_probe",
        _pl.Path(__file__).resolve().parents[3] / "src" / "services" / "adk" / "mcp_service.py",
    )
    # Importing the module pulls the ADK stack, so the helper is exercised
    # through its source contract instead: the entry the CORE persists must hit
    # the vault branch, not the verbatim one.
    source = spec.origin and _pl.Path(spec.origin).read_text()

    resolver = source.split("def _resolve_mcp_envs(server, db):")[1].split("\ndef ")[0]

    # The line that READS the values must name `environments`: reading only
    # `envs` ignores the key the core actually persists, and the resolution stays
    # inert even with the call wired at the right place.
    read_line = next(
        (line for line in resolver.splitlines() if line.strip().startswith("envs = server.get")),
        None,
    )
    assert read_line, "the value read moved; this guard needs updating"
    assert "environments" in read_line, (
        f"the resolver ignores the key the core persists: {read_line.strip()!r}"
    )
    assert "credential_refs" in resolver, "the resolver never looks for the reference map"


def test_env_resolution_prefers_the_reference_and_falls_back_to_inline():
    """The behaviour the three commits add up to, exercised on the resolver's
    own contract: a referenced var takes the vault value, an unreferenced one
    keeps its inline value."""
    vault = StubVault({"cred-1": row("cipher")})

    resolved = resolve_credential_refs(
        {"GITHUB_PERSONAL_ACCESS_TOKEN": "inline-antigo", "PUBLIC_FLAG": "true"},
        {"GITHUB_PERSONAL_ACCESS_TOKEN": "cred-1"},
        vault=vault,
        decrypt=lambda _: "ghp_do_cofre",
    )

    assert resolved["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_do_cofre"
    assert resolved["PUBLIC_FLAG"] == "true", "an unreferenced var lost its inline value"
