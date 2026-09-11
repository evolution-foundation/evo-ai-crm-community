"""Unit tests for the Knowledge Nexus search tool — EVO-1110.

Covers happy path, validation, every HTTP status branch, timeout, network
error, secret masking, base-URL normalization, override/passthrough of optional
params, and the absence of internal-only headers.
"""

from __future__ import annotations

import logging
from typing import Any, Dict
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from src.services.adk.tools.knowledge_nexus import create_knowledge_nexus_search_tool


REAL_SECRET = "evo_k_realkey.real_secret_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xx"


def _build_response(status_code: int, json_body: Any = None, text: str = "") -> MagicMock:
    """Construct a MagicMock that walks like an httpx.Response for our handler."""

    response = MagicMock()
    response.status_code = status_code
    response.text = text if text else (str(json_body) if json_body is not None else "")
    if json_body is None:
        response.json.side_effect = ValueError("no json")
    else:
        response.json.return_value = json_body
    return response


def _patch_post(response_or_exc):
    """Patch httpx.AsyncClient so .post() returns / raises the given value.

    Returns a context manager + the AsyncMock we can assert against.
    """

    if isinstance(response_or_exc, Exception):
        post = AsyncMock(side_effect=response_or_exc)
    else:
        post = AsyncMock(return_value=response_or_exc)

    client_instance = MagicMock()
    client_instance.post = post
    client_cm = MagicMock()
    client_cm.__aenter__ = AsyncMock(return_value=client_instance)
    client_cm.__aexit__ = AsyncMock(return_value=False)

    patcher = patch(
        "src.services.adk.tools.knowledge_nexus.search_tool.httpx.AsyncClient",
        return_value=client_cm,
    )
    return patcher, post


def _make_tool(**overrides) -> Any:
    base = {
        "nexus_base_url": "https://nexus.example.io",
        "nexus_api_key": REAL_SECRET,
        "space_id": "uuid-space-1",
        "default_top_k": 10,
        "default_filters": None,
        "timeout_seconds": 15.0,
    }
    base.update(overrides)
    tool = create_knowledge_nexus_search_tool(**base)
    # FunctionTool exposes the original callable via .func
    return tool.func


@pytest.mark.asyncio
async def test_happy_path_slims_results():
    """AC5: 200 returns slim chunks with only doc_title, content, content_type, final_score."""

    nexus_payload = {
        "results": [
            {
                "chunk_id": "c-1",
                "document_id": "d-1",
                "doc_title": "Refund Policy",
                "content_type": "policy",
                "unit_id": "u-1",
                "chunk_idx": 0,
                "chunk_type": "paragraph",
                "content": "Customers may request a refund within 30 days.",
                "chunk_metadata": {"foo": "bar"},
                "rrf_score": 0.5,
                "final_score": 0.93,
            },
            {
                "doc_title": "FAQ",
                "content_type": "faq",
                "content": "Yes, refunds are allowed.",
                "final_score": 0.71,
            },
        ],
        "total": 2,
    }
    handler = _make_tool()
    patcher, post = _patch_post(_build_response(200, nexus_payload))
    with patcher:
        result = await handler(query="refund policy", tool_context=MagicMock())

    assert result["status"] == "success"
    assert result["total"] == 2
    assert len(result["results"]) == 2
    first = result["results"][0]
    assert set(first.keys()) == {"doc_title", "content", "content_type", "final_score"}
    assert first["doc_title"] == "Refund Policy"
    assert first["final_score"] == 0.93
    for forbidden in ("chunk_id", "document_id", "unit_id", "rrf_score", "chunk_metadata"):
        assert forbidden not in first
    post.assert_awaited_once()


@pytest.mark.asyncio
async def test_empty_query_short_circuits():
    """AC6: empty/whitespace query must not hit Nexus."""

    handler = _make_tool()
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        for blank in ("", "   "):
            result = await handler(query=blank, tool_context=MagicMock())
            assert result == {"status": "failed", "error": "query cannot be empty"}
    post.assert_not_called()


@pytest.mark.asyncio
async def test_status_401_returns_actionable_error():
    """AC7: 401 surfaces a guidance message."""

    handler = _make_tool()
    patcher, _post = _patch_post(_build_response(401, {"error": "unauthorized"}))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "Unauthorized" in result["error"]
    assert "Nexus API key" in result["error"]


@pytest.mark.asyncio
async def test_status_403_mentions_space_id():
    """AC8: 403 names the space_id."""

    handler = _make_tool(space_id="uuid-space-7")
    patcher, _post = _patch_post(_build_response(403, {"error": "forbidden"}))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "space_id=uuid-space-7" in result["error"]


@pytest.mark.asyncio
async def test_status_429_returns_rate_limit_message():
    """AC9: 429 surfaces a rate-limit message."""

    handler = _make_tool()
    patcher, _post = _patch_post(_build_response(429, {"error": "rate"}))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "Rate limit exceeded" in result["error"]


@pytest.mark.asyncio
async def test_status_500_returns_generic_error():
    """5xx surfaces the status code plus a snippet of the response body."""

    handler = _make_tool()
    patcher, _post = _patch_post(_build_response(500, text="internal explosion"))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "Nexus error: 500" in result["error"]
    assert "internal explosion" in result["error"]


@pytest.mark.asyncio
async def test_timeout_is_bounded_and_reported():
    """AC10: TimeoutException maps to a user-facing message including the duration."""

    handler = _make_tool(timeout_seconds=15.0)
    patcher, _post = _patch_post(httpx.TimeoutException("slow"))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "timed out after 15.0s" in result["error"]


@pytest.mark.asyncio
async def test_network_error_is_reported(caplog):
    """AC11: ConnectError surfaces "Network error" and does not leak the API key."""

    caplog.set_level(logging.DEBUG, logger="src.services.adk.tools.knowledge_nexus.search_tool")
    handler = _make_tool()
    patcher, _post = _patch_post(httpx.ConnectError("DNS fail"))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "Network error reaching Nexus" in result["error"]
    for record in caplog.records:
        assert REAL_SECRET not in record.getMessage()


@pytest.mark.asyncio
async def test_trailing_slash_base_url_does_not_double_up():
    """AC13: base URL with trailing slash yields a single `/` in the request URL."""

    handler = _make_tool(nexus_base_url="https://nexus.example.io/")
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        await handler(query="x", tool_context=MagicMock())

    called_url = post.call_args.args[0]
    assert called_url == "https://nexus.example.io/api/knowledge/v1/spaces/uuid-space-1/search"
    assert "//api" not in called_url


@pytest.mark.asyncio
async def test_top_k_override_and_filters_passthrough():
    """AC12: explicit top_k overrides default; filters are forwarded."""

    handler = _make_tool(default_top_k=10, default_filters={"content_type": "faq"})
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        await handler(query="hello", tool_context=MagicMock(), top_k=3)

    sent_body = post.call_args.kwargs["json"]
    assert sent_body == {
        "query": "hello",
        "top_k": 3,
        "filters": {"content_type": "faq"},
    }


@pytest.mark.asyncio
async def test_headers_contain_bearer_and_omit_internal_headers():
    """AC14: Authorization Bearer + Content-Type only — no internal CSRF headers."""

    handler = _make_tool()
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        await handler(query="x", tool_context=MagicMock())

    sent_headers: Dict[str, str] = post.call_args.kwargs["headers"]
    assert sent_headers["Authorization"] == f"Bearer {REAL_SECRET}"
    assert sent_headers["Content-Type"] == "application/json"
    assert "X-Requested-With" not in sent_headers
    assert "X-Knowledge-Connection" not in sent_headers


@pytest.mark.asyncio
async def test_api_key_is_not_logged_on_success(caplog):
    """AC15: API key never appears in log records (success path)."""

    caplog.set_level(logging.DEBUG, logger="src.services.adk.tools.knowledge_nexus.search_tool")
    handler = _make_tool()
    patcher, _post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        await handler(query="x", tool_context=MagicMock())

    for record in caplog.records:
        assert REAL_SECRET not in record.getMessage()
        assert REAL_SECRET not in str(record.args or "")


@pytest.mark.asyncio
async def test_api_key_is_not_logged_on_failure(caplog):
    """AC15: API key never appears in log records (failure path)."""

    caplog.set_level(logging.DEBUG, logger="src.services.adk.tools.knowledge_nexus.search_tool")
    handler = _make_tool()
    patcher, _post = _patch_post(_build_response(500, text="boom"))
    with patcher:
        await handler(query="x", tool_context=MagicMock())

    for record in caplog.records:
        assert REAL_SECRET not in record.getMessage()
        assert REAL_SECRET not in str(record.args or "")


@pytest.mark.asyncio
async def test_status_200_with_non_json_body_returns_failure():
    """Review F7: 200 + non-JSON body falls through to a friendly failure."""

    handler = _make_tool()
    response = MagicMock()
    response.status_code = 200
    response.text = "not json"
    response.json.side_effect = ValueError("no json")
    patcher, _post = _patch_post(response)
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result == {
        "status": "failed",
        "error": "Nexus returned a non-JSON 200 response.",
    }


@pytest.mark.asyncio
async def test_empty_default_filters_omitted_from_body():
    """Review F7: empty default_filters must not put 'filters' in the body."""

    handler = _make_tool(default_filters={})
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        await handler(query="hello", tool_context=MagicMock())

    sent_body = post.call_args.kwargs["json"]
    assert sent_body == {"query": "hello", "top_k": 10}
    assert "filters" not in sent_body


@pytest.mark.asyncio
async def test_none_default_filters_omitted_from_body():
    """Review F7: default_filters=None must not put 'filters' in the body."""

    handler = _make_tool(default_filters=None)
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        await handler(query="hello", tool_context=MagicMock())

    assert "filters" not in post.call_args.kwargs["json"]


@pytest.mark.asyncio
async def test_unexpected_exception_traceback_never_leaks_api_key(caplog):
    """Review F1/F7: unexpected exception path must not log the API key
    (we use logger.error without exc_info to avoid frame-locals leakage).
    """

    caplog.set_level(logging.DEBUG, logger="src.services.adk.tools.knowledge_nexus.search_tool")
    handler = _make_tool()
    # Generic Exception flowing through the bare-except branch
    patcher, _post = _patch_post(RuntimeError("boom"))
    with patcher:
        result = await handler(query="x", tool_context=MagicMock())

    assert result["status"] == "failed"
    assert "Unexpected error" in result["error"]
    for record in caplog.records:
        assert REAL_SECRET not in record.getMessage()
        assert REAL_SECRET not in str(record.args or "")
        # No exception info attached → no traceback formatting at all
        assert record.exc_info is None
        if record.exc_text:
            assert REAL_SECRET not in record.exc_text


@pytest.mark.asyncio
async def test_top_k_non_integer_string_is_rejected():
    """F3: top_k='abc' returns a friendly validation error without hitting Nexus."""

    handler = _make_tool()
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    with patcher:
        result = await handler(
            query="x",
            tool_context=MagicMock(),
            top_k="abc",  # type: ignore[arg-type]
        )

    assert result == {"status": "failed", "error": "top_k must be an integer."}
    post.assert_not_called()


@pytest.mark.asyncio
async def test_top_k_zero_or_negative_is_rejected():
    """F3: top_k <= 0 returns a friendly validation error without hitting Nexus."""

    handler = _make_tool()
    patcher, post = _patch_post(_build_response(200, {"results": [], "total": 0}))
    for bad in (0, -1, -100):
        with patcher:
            result = await handler(query="x", tool_context=MagicMock(), top_k=bad)
        assert result == {
            "status": "failed",
            "error": "top_k must be a positive integer.",
        }
    post.assert_not_called()
