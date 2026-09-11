"""EVO-2166: agent API key validation must not turn infra/DB errors into 401.

An infrastructure error (dead pooled connection, DB down/timeout) during agent
key validation is NOT "invalid key" — it is "could not determine". It must
surface as a retryable 5xx, never as a silent, non-retryable 401 that drops the
customer's message.
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from sqlalchemy.exc import OperationalError, SQLAlchemyError

from src.services.agent_service import validate_agent_api_key, AgentValidationError

AGENT_ID = "c9cbd608-ee35-49fe-8200-fadaaa682d87"


def _agent(api_key="stored-key", name="interrural"):
    a = MagicMock()
    a.id = AGENT_ID
    a.name = name
    a.config = {"api_key": api_key}
    return a


def _db_returning(agent):
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = agent
    return db


# --------------------------------------------------------------------------- #
# validate_agent_api_key
# --------------------------------------------------------------------------- #
def test_valid_key_returns_valid_true():
    db = _db_returning(_agent(api_key="k"))
    res = asyncio.run(validate_agent_api_key(db, AGENT_ID, "k"))
    assert res["valid"] is True


def test_wrong_key_returns_valid_false_not_raise():
    db = _db_returning(_agent(api_key="k"))
    res = asyncio.run(validate_agent_api_key(db, AGENT_ID, "WRONG"))
    assert res["valid"] is False  # auth decision, still 401 upstream


def test_infra_sqlalchemy_error_raises_agent_validation_error():
    db = MagicMock()
    db.query.side_effect = SQLAlchemyError("server closed the connection unexpectedly")
    with pytest.raises(AgentValidationError):
        asyncio.run(validate_agent_api_key(db, AGENT_ID, "k"))


def test_infra_operational_error_raises_agent_validation_error():
    db = MagicMock()
    db.query.side_effect = OperationalError("SELECT 1", {}, Exception("server closed"))
    with pytest.raises(AgentValidationError):
        asyncio.run(validate_agent_api_key(db, AGENT_ID, "k"))


# --------------------------------------------------------------------------- #
# EvoAuthMiddleware: infra error -> 503 (not 401); invalid key -> 401
# --------------------------------------------------------------------------- #
def _build_request():
    from starlette.requests import Request

    scope = {
        "type": "http",
        "method": "POST",
        "path": f"/api/v1/a2a/{AGENT_ID}",
        "headers": [(b"authorization", b"Bearer sometoken")],
        "query_string": b"",
    }
    return Request(scope)


def _run_dispatch(validate_mock):
    from src.middleware.evo_auth import EvoAuthMiddleware

    mw = EvoAuthMiddleware(MagicMock())
    mw._extract_token = lambda req: ("sometoken", "bearer")  # avoid HttpUtils plumbing

    call_next = AsyncMock()
    auth_svc = MagicMock()
    auth_svc.validate_token = AsyncMock(return_value=None)  # forces the agent-key fallback

    def fake_get_db():
        yield MagicMock()

    with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_svc), patch(
        "src.middleware.evo_auth.get_db", new=fake_get_db
    ), patch("src.services.agent_service.validate_agent_api_key", new=validate_mock):
        response = asyncio.run(mw.dispatch(_build_request(), call_next))
    return response, call_next


def test_middleware_returns_503_on_infra_error_not_401():
    validate = AsyncMock(side_effect=AgentValidationError("server closed the connection"))
    response, call_next = _run_dispatch(validate)
    assert response.status_code == 503  # retryable, NOT a silent 401
    call_next.assert_not_called()


def test_middleware_still_401_on_invalid_key():
    validate = AsyncMock(
        return_value={"valid": False, "agent_id": AGENT_ID, "agent_name": None}
    )
    response, call_next = _run_dispatch(validate)
    assert response.status_code == 401  # genuine auth failure stays 401
    call_next.assert_not_called()


# --------------------------------------------------------------------------- #
# EvoAuthMiddleware main agent-api-key path (an already-validated agent token,
# NOT the token-fallback above). This is the path named in the incident
# root-cause, so it gets its own coverage: its 503 relies on the outer
# `except AgentValidationError`, and a stray inner `except Exception` would
# silently regress it back to 401 — this test guards against that.
# --------------------------------------------------------------------------- #
def _run_dispatch_agent_key_path(validate_mock):
    from src.middleware.evo_auth import EvoAuthMiddleware

    mw = EvoAuthMiddleware(MagicMock())
    mw._extract_token = lambda req: ("sometoken", "api_access_token")

    call_next = AsyncMock()
    auth_response = MagicMock()
    # Detected as an agent token whose id matches the path -> main agent-key path
    auth_response.metadata = {"agent_id": AGENT_ID}
    auth_svc = MagicMock()
    auth_svc.validate_token = AsyncMock(return_value=auth_response)

    def fake_get_db():
        yield MagicMock()

    with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_svc), patch(
        "src.middleware.evo_auth.get_db", new=fake_get_db
    ), patch("src.services.agent_service.validate_agent_api_key", new=validate_mock):
        response = asyncio.run(mw.dispatch(_build_request(), call_next))
    return response, call_next


def test_middleware_main_path_returns_503_on_infra_error_not_401():
    validate = AsyncMock(side_effect=AgentValidationError("server closed the connection"))
    response, call_next = _run_dispatch_agent_key_path(validate)
    assert response.status_code == 503  # retryable, NOT a silent 401
    call_next.assert_not_called()


def test_middleware_main_path_still_401_on_invalid_key():
    validate = AsyncMock(
        return_value={"valid": False, "agent_id": AGENT_ID, "agent_name": None}
    )
    response, call_next = _run_dispatch_agent_key_path(validate)
    assert response.status_code == 401  # genuine auth failure stays 401
    call_next.assert_not_called()
