"""The CALL PATH of vault header resolution for remote MCP servers.

These assert on the SOURCE of the assembly point, not on the resolver. A
resolver with no caller passes its own unit tests while a remote MCP configured
with `credential_refs` and no inline header goes out UNAUTHENTICATED.
"""

import pathlib
import re

import pytest

_SERVICE = (
    pathlib.Path(__file__).resolve().parents[3] / "src" / "services" / "adk" / "mcp_service.py"
)


@pytest.fixture(scope="module")
def source() -> str:
    return _SERVICE.read_text()


def _assembly_block(source: str) -> str:
    """The literal that builds server_config for a custom (remote) MCP server."""
    match = re.search(
        r"server_config = \{\s*\n\s*\"url\": custom_server\.url,\s*\n(?P<headers>.*?)\n\s*\}",
        source,
        re.S,
    )
    assert match, "the custom MCP server_config literal moved; this guard needs updating"
    return match.group("headers")


def test_remote_mcp_assembly_resolves_headers_through_the_vault(source: str) -> None:
    """The assembly point must call the resolver, not read the column raw."""
    headers_line = _assembly_block(source)

    assert "_resolve_mcp_headers" in headers_line, (
        "the assembly point builds headers without the vault resolver: "
        f"got {headers_line.strip()!r}"
    )
    assert "custom_server.headers or {}" not in headers_line, (
        "the raw header read is still there, so credential_refs is ignored"
    )


def test_the_resolver_has_a_caller_outside_its_own_definition(source: str) -> None:
    """The regression guard for the whole defect class.

    A resolution helper with no caller is dead code that a green suite cannot
    see. This fails the moment the call is removed again.
    """
    uses = [
        line
        for line in source.splitlines()
        if "_resolve_mcp_headers" in line and not line.strip().startswith("def ")
    ]

    assert uses, "_resolve_mcp_headers has no caller: it is dead code again"


def test_official_mcp_env_is_resolved_through_the_vault(source: str) -> None:
    """The env vars of an official MCP server must go through the resolver, not
    be copied verbatim, or a vault reference is never honoured.
    """
    match = re.search(
        r"if \"env\" not in server_config:(?P<body>.*?)\n\n",
        source,
        re.S,
    )
    assert match, "the env assembly block moved; this guard needs updating"

    body = match.group("body")
    assert "_resolve_mcp_envs" in body, (
        f"env vars are still copied verbatim, bypassing the vault: {body.strip()!r}"
    )


_CONTEXT = (
    pathlib.Path(__file__).resolve().parents[3] / "src" / "services" / "adk" / "mcp_context.py"
)


@pytest.fixture(scope="module")
def context_source() -> str:
    return _CONTEXT.read_text()


# Review finding 13: both log sites masked ONLY `authorization`, so `X-API-Key`
# and any custom auth header went to the logs in cleartext.
def test_header_values_are_never_logged_verbatim(context_source: str) -> None:
    offending = [
        line.strip()
        for line in context_source.splitlines()
        if "Header values" in line
    ]

    assert not offending, f"header values still reach the log: {offending}"


def test_masking_covers_every_non_safe_header_name(context_source: str) -> None:
    """The classification must be an allowlist of SAFE names, not a denylist of
    auth-looking ones: a denylist misses `X-Tenant-Auth` and friends, which is
    the same lesson the backend redaction already learned."""
    assert "_SAFE_HEADER_NAMES" in context_source, (
        "masking is not derived from a safe-name allowlist"
    )
    assert 'key.lower() == "authorization"' not in context_source, (
        "the single-name heuristic is still there, so other auth headers leak"
    )


# The env var key on the AGENT's MCP entry is `environments`, not `envs`: the
# front writes `environments` and the core rewrites the persisted entry as
# exactly {id, environments, tools}. A guard on `envs` never fires for an agent
# configured through the screen, leaving the resolution inert even when wired.
def test_env_resolution_reads_the_key_the_pipeline_actually_writes(source: str) -> None:
    guard = re.search(
        r"(?P<cond>if server\.get\([^\n]*\n?[^\n]*\):)\s*\n\s*if \"env\" not in server_config",
        source,
    )
    assert guard, "the env guard moved; this test needs updating"

    assert "environments" in guard.group("cond"), (
        "the guard reads a key the pipeline never persists: "
        f"got {guard.group('cond')!r}, and the core writes 'environments'"
    )


def test_env_resolver_reads_environments_too(source: str) -> None:
    body = re.search(r"def _resolve_mcp_envs\(server, db\):(?P<body>.*?)\ndef ", source, re.S)
    assert body, "_resolve_mcp_envs moved; this test needs updating"

    assert "environments" in body.group("body"), (
        "_resolve_mcp_envs reads only 'envs', which the pipeline never writes"
    )
