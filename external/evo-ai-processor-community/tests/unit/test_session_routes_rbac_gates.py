"""EVO-2124 — Contract test: session_routes RBAC gates.

Per-agent routes MUST be gated by `ai_agents.<action>`. Cross-agent routes
(metrics/account/bulk) MUST remain `ai_chat_sessions.<action>`. Verifies at
the router level via dependency introspection — no HTTP boot, no mocks.
"""
from __future__ import annotations
import pytest
from fastapi.params import Depends
from src.middleware.permissions import PermissionChecker
from src.api import session_routes


# (method, path) -> (expected_resource, expected_action)
EXPECTED_GATES: dict[tuple[str, str], tuple[str, str]] = {
    ("GET",    "/sessions/metrics"):                    ("ai_chat_sessions", "metrics"),
    ("POST",   "/sessions/{agent_id}"):                 ("ai_agents",        "write"),
    ("GET",    "/sessions/account"):                    ("ai_chat_sessions", "read"),
    ("GET",    "/sessions/agent/{agent_id}"):           ("ai_agents",        "read"),
    ("DELETE", "/sessions/bulk"):                       ("ai_chat_sessions", "bulk_delete"),
    ("GET",    "/sessions/{session_id}"):               ("ai_agents",        "read"),
    ("GET",    "/sessions/{session_id}/messages"):      ("ai_agents",        "read"),
    # Deleting a session is a delete, not a write: the role editor renders Write
    # and Delete as separate groups, so gating this on `write` would let an admin
    # who deliberately withheld Delete still have sessions destroyed. Matches the
    # approved decision table on EVO-2124.
    ("DELETE", "/sessions/{session_id}"):               ("ai_agents",        "delete"),
    ("GET",    "/sessions/{session_id}/metadata"):      ("ai_agents",        "read"),
    ("PUT",    "/sessions/{session_id}/metadata"):      ("ai_agents",        "write"),
    ("DELETE", "/sessions/{session_id}/metadata"):      ("ai_agents",        "write"),
}

CROSS_AGENT_PATHS = {"/sessions/metrics", "/sessions/account", "/sessions/bulk"}

# Internal endpoints authenticated by API key (agent bots / CRM sync); they do NOT
# use RequirePermission by design. Explicit allowlist — any NEW gate-less route
# not listed here fails the contract test, forcing a review.
API_KEY_AUTH_PATHS: set[tuple[str, str]] = {
    ("POST",   "/sessions/sync/{agent_id}"),
    ("DELETE", "/sessions/sync/{session_id}"),
    ("POST",   "/sessions/{session_id}/events"),
}


def _iter_permission_checkers(route) -> list[PermissionChecker]:
    """Walk a route's dependant tree, collect PermissionChecker instances.
    Mirror of _iter_permission_checkers in test_integrations_rbac_gates.py."""
    found: list[PermissionChecker] = []
    seen: set[int] = set()

    def walk(dep):
        if dep is None or id(dep) in seen:
            return
        seen.add(id(dep))
        call = getattr(dep, "call", None) or getattr(dep, "dependency", None)
        if isinstance(call, PermissionChecker):
            found.append(call)
        for sub in getattr(dep, "dependencies", []) or []:
            walk(sub)

    for dep in getattr(route, "dependencies", []) or []:
        if isinstance(dep, Depends):
            call = dep.dependency
            if isinstance(call, PermissionChecker):
                found.append(call)
    dependant = getattr(route, "dependant", None)
    if dependant is not None:
        walk(dependant)
    return found


# F3 fix: only iterate HTTP methods we author; guard against auto-added HEAD/OPTIONS
_RELEVANT_METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE"}


def _router_route_keys() -> list[tuple[str, str]]:
    """Actual (method, path) pairs registered on session_routes.router."""
    keys = []
    for route in session_routes.router.routes:
        for method in getattr(route, "methods", set()) & _RELEVANT_METHODS:
            keys.append((method, getattr(route, "path", route.name)))
    return keys


# F2 fix: defensive assertion — session_routes.router MUST carry the /sessions
# prefix so route.path values line up with EXPECTED_GATES. If someone moves the
# prefix to the main app mount, this catches it before every parametrized case
# blows up with a cryptic "not in EXPECTED_GATES".
def test_router_prefix_invariant():
    assert getattr(session_routes.router, "prefix", "") == "/sessions", (
        "session_routes.router prefix changed — EXPECTED_GATES paths assume "
        "'/sessions' prefix lives on the APIRouter itself, not on the app mount."
    )


# EVO-2124 review M2: parametrize on the STATIC EXPECTED_GATES keys, not on
# whatever the router happens to expose at collect time. If the router breaks
# (empty routes, import shim, renamed symbol), the old "iterate router.routes"
# version silently collected zero cases and the whole guard passed. Now every
# expected gate becomes a mandatory case — router regression fails loudly.
@pytest.mark.parametrize("key", sorted(EXPECTED_GATES.keys()))
def test_every_expected_gate_present(key):
    """Every entry in EXPECTED_GATES must exist on the router with the right
    (resource, action). Regression guard for EVO-2124."""
    method, path = key
    expected_resource, expected_action = EXPECTED_GATES[key]

    matches = [
        r for r in session_routes.router.routes
        if method in getattr(r, "methods", set())
        and getattr(r, "path", r.name) == path
    ]
    assert len(matches) == 1, (
        f"Expected exactly one route for {method} {path}, found {len(matches)} — "
        f"router refactor removed or duplicated the endpoint."
    )
    checkers = _iter_permission_checkers(matches[0])
    assert checkers, (
        f"{method} {path}: missing RequirePermission gate — EVO-2124 regression."
    )
    assert any(
        c.resource == expected_resource and c.action == expected_action
        for c in checkers
    ), (
        f"{method} {path}: expected gate ({expected_resource!r}, "
        f"{expected_action!r}), found {[(c.resource, c.action) for c in checkers]}"
    )


def test_no_unexpected_session_routes():
    """Any route on the router that is neither in EXPECTED_GATES nor in the
    API_KEY_AUTH_PATHS allowlist is a new endpoint that slipped in without
    updating the contract. Force a review."""
    unknown = [
        key for key in _router_route_keys()
        if key not in EXPECTED_GATES and key not in API_KEY_AUTH_PATHS
    ]
    assert not unknown, (
        "New session route(s) added without updating EXPECTED_GATES or "
        "API_KEY_AUTH_PATHS:\n  - " + "\n  - ".join(f"{m} {p}" for m, p in unknown)
    )


def test_ai_chat_sessions_gates_stay_only_on_cross_agent_routes():
    """Sanity guard: only /metrics, /account, /bulk keep the cross-agent
    resource. Any per-agent route regressing to ai_chat_sessions fails here."""
    offenders = []
    for route in session_routes.router.routes:
        path = getattr(route, "path", route.name)
        methods = getattr(route, "methods", set()) & _RELEVANT_METHODS
        if any((m, path) in API_KEY_AUTH_PATHS for m in methods):
            continue
        for chk in _iter_permission_checkers(route):
            if chk.resource == "ai_chat_sessions" and path not in CROSS_AGENT_PATHS:
                offenders.append(f"{path} -> ({chk.resource}, {chk.action})")
    assert not offenders, (
        "Per-agent routes must NOT use ai_chat_sessions — EVO-2124 regression:\n  - "
        + "\n  - ".join(offenders)
    )
