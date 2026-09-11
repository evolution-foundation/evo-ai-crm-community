"""Unit tests for the custom MCP "Test connection" service — EVO-2139.

The Test button used to hit a raw `GET /health`, a route no compliant MCP
server exposes, so it failed for every real server. The fix reuses
`_discover_async` (the same real MCP handshake the production `discover-tools`
endpoint runs) and returns a success/failure envelope the Go core-service
delegates to.

No network: `_discover_async` is patched so the handshake never actually runs.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from src.schemas.schemas import CustomMCPDiscoverToolsCreate
from src.services import custom_mcp_server_service

URL = "https://mcp.example/mcp"


def _tools(n: int) -> list[dict]:
    return [{"id": f"t{i}", "name": f"tool_{i}"} for i in range(n)]


@pytest.mark.asyncio
async def test_success_reports_tools_count_and_passes_minimal_config():
    """A successful handshake returns success=True with the discovered count,
    and calls `_discover_async` with the same `{url, headers}` config the
    production discover-tools path uses — nothing more, nothing less."""
    mock = AsyncMock(return_value=_tools(3))
    with patch.object(custom_mcp_server_service, "_discover_async", mock):
        result = await custom_mcp_server_service.test_custom_mcp_server_connection(
            CustomMCPDiscoverToolsCreate(
                url=URL, headers={"Authorization": "Bearer sk-live"}
            )
        )

    assert result["success"] is True
    assert result["status_code"] == 200
    assert result["tools_count"] == 3
    assert result["url_tested"] == URL
    assert "3" in result["message"]
    assert "response_time" in result

    mock.assert_awaited_once_with(
        {"url": URL, "headers": {"Authorization": "Bearer sk-live"}}
    )


@pytest.mark.asyncio
async def test_success_with_zero_tools_is_a_legitimate_zero():
    """A reachable server that advertises no tools is still a success, and
    tools_count is an explicit 0 (the Go side drops `omitempty` so this 0
    reaches the UI instead of a DB-stale fallback)."""
    with patch.object(
        custom_mcp_server_service, "_discover_async", AsyncMock(return_value=[])
    ):
        result = await custom_mcp_server_service.test_custom_mcp_server_connection(
            CustomMCPDiscoverToolsCreate(url=URL, headers=None)
        )

    assert result["success"] is True
    assert result["tools_count"] == 0


@pytest.mark.asyncio
async def test_none_headers_default_to_empty_dict():
    """Headers omitted by the caller reach the handshake as {}, mirroring the
    `headers or {}` guard in discover-tools."""
    mock = AsyncMock(return_value=[])
    with patch.object(custom_mcp_server_service, "_discover_async", mock):
        await custom_mcp_server_service.test_custom_mcp_server_connection(
            CustomMCPDiscoverToolsCreate(url=URL, headers=None)
        )

    mock.assert_awaited_once_with({"url": URL, "headers": {}})


@pytest.mark.asyncio
async def test_handshake_failure_returns_envelope_not_exception():
    """A failed handshake surfaces as success=False with the error propagated,
    NOT as a raised exception the endpoint would turn into a 500."""
    mock = AsyncMock(side_effect=RuntimeError("connection refused"))
    with patch.object(custom_mcp_server_service, "_discover_async", mock):
        result = await custom_mcp_server_service.test_custom_mcp_server_connection(
            CustomMCPDiscoverToolsCreate(url=URL, headers={})
        )

    assert result["success"] is False
    assert "connection refused" in result["error"]
    assert result["url_tested"] == URL
    assert "response_time" in result
