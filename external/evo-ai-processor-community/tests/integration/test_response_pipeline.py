"""Integration tests for EVO-972.

These tests mount a minimal FastAPI app that reuses the processor's
``success_response`` / ``error_response`` helpers (same ones used by
``session_routes``, ``a2a_routes``, ``chat_routes``) and verify that a
payload shaped like a Google ADK event — with ``set``/``frozenset`` fields
deep in the tree — round-trips as HTTP 200 with the expected JSON body.

This is the end-to-end regression guard for AC 1 / AC 3 / AC 4 of EVO-972:
the test chat's ``GET /sessions/{id}/messages`` endpoint blew up with
``TypeError: Object of type set is not JSON serializable`` on exactly this
shape before SafeJSONResponse was wired into the response helpers.

For AC 2 specifically, ``TestA2AMessageSendErrorEnvelope`` exercises
``handle_message_send`` directly to guard the JSON-RPC error envelope shape
the bot-runtime depends on — code-review HIGH-1 found this branch was
returning the processor's standard error envelope instead, which would have
broken the WhatsApp channel reply flow on any agent-execution exception.
"""

from __future__ import annotations

import asyncio
import uuid
from unittest.mock import AsyncMock, patch

from fastapi import FastAPI, Request
from fastapi.testclient import TestClient

from src.utils.response import error_response, success_response


def _build_adk_like_event() -> dict:
    """Emulate the `event.model_dump()` shape that broke prod."""
    return {
        "id": "evt_123",
        "author": "assistant",
        "actions": {
            "artifact_delta": {"doc:1", "doc:2"},
            "state_delta": {},
            "transfer_to_agent": None,
        },
        "content": {
            "parts": [
                {
                    "text": "hello",
                    "metadata": {
                        # The exact shape that triggers review #5 (sets inside
                        # lists inside lists).
                        "tool_calls": [[{"tools_used": frozenset({"search", "calc"})}]],
                    },
                }
            ]
        },
    }


def _make_app() -> FastAPI:
    app = FastAPI()

    @app.get("/messages")
    async def messages(request: Request):
        return success_response(data=[_build_adk_like_event()])

    @app.get("/boom")
    async def boom(request: Request):
        return error_response(
            request=request,
            code="EXTERNAL_SERVICE_ERROR",
            message="Authentication service is temporarily unavailable.",
            details={
                "upstream_service": "evo_auth",
                "upstream_url": "http://evo-auth:3001/api/v1/auth/validate",
                "error_type": "connection_refused",
            },
            status_code=503,
        )

    return app


class TestSuccessResponseWithAdkEvent:
    def test_messages_endpoint_returns_200_with_set_payload(self) -> None:
        # Before the fix, the `artifact_delta` / `tools_used` sets tripped
        # json.dumps at render time and Starlette re-raised as a 500.
        client = TestClient(_make_app())

        response = client.get("/messages")

        assert response.status_code == 200
        body = response.json()
        assert body["success"] is True
        event = body["data"][0]
        assert sorted(event["actions"]["artifact_delta"]) == ["doc:1", "doc:2"]
        deep_tools = event["content"]["parts"][0]["metadata"]["tool_calls"][0][0][
            "tools_used"
        ]
        assert sorted(deep_tools) == ["calc", "search"]


class TestErrorResponseSurface:
    def test_503_carries_structured_details_and_standard_shape(self) -> None:
        client = TestClient(_make_app())

        response = client.get("/boom")

        assert response.status_code == 503
        body = response.json()
        assert body["success"] is False
        # Aligned with the registry constant used by map_status_to_error_code(503)
        # so all 503 paths in the service share one code.
        assert body["error"]["code"] == "EXTERNAL_SERVICE_ERROR"
        assert body["error"]["details"]["upstream_service"] == "evo_auth"
        assert body["error"]["details"]["error_type"] == "connection_refused"
        assert body["meta"]["path"] == "/boom"
        assert body["meta"]["method"] == "GET"


class TestA2AMessageSendErrorEnvelope:
    """Regression guard for code-review HIGH-1.

    Every other A2A handler (tasks/get, tasks/cancel, push_notification_*)
    returns a top-level JSON-RPC ``{jsonrpc, id, error}`` envelope on failure.
    ``handle_message_send`` was returning the processor's standard
    ``{success, error, meta}`` envelope with the JSON-RPC frame nested under
    ``details``, which would break ``evo-bot-runtime``'s WhatsApp reply flow
    (EVO-972 AC #2) on any agent-execution exception. This test pins the
    envelope shape so the regression cannot return silently.
    """

    @staticmethod
    def _read_body(response) -> dict:
        import json
        return json.loads(response.body)

    def test_exception_branch_returns_jsonrpc_envelope(self) -> None:
        from src.api import a2a_routes

        request_id = "req-abc-123"
        agent_id = uuid.uuid4()
        params = {
            "message": {
                "messageId": "msg-1",
                "parts": [{"type": "text", "text": "hello"}],
            },
            "contextId": str(uuid.uuid4()),
            "userId": str(uuid.uuid4()),
        }

        # Force the agent execution path to fail. ``run_agent`` is the heavy
        # ADK call; replacing it with a raising AsyncMock drops us straight
        # into the exception handler we want to characterize.
        request = AsyncMock(spec=Request)
        with patch.object(
            a2a_routes,
            "run_agent",
            new=AsyncMock(side_effect=RuntimeError("boom")),
        ), patch.object(
            a2a_routes, "extract_conversation_history", new=AsyncMock(return_value=[])
        ), patch.object(
            a2a_routes, "extract_history_from_params", return_value=[]
        ):
            response = asyncio.run(
                a2a_routes.handle_message_send(
                    agent_id=agent_id,
                    params=params,
                    request_id=request_id,
                    request=request,
                    db=None,
                )
            )

        body = self._read_body(response)
        # JSON-RPC envelope at top level — NOT wrapped in {success, error, meta}
        assert body["jsonrpc"] == "2.0"
        assert body["id"] == request_id
        assert body["error"]["code"] == -32603
        assert body["error"]["message"] == "Agent execution failed"
        assert "boom" in body["error"]["data"]["error"]
        # Negative assertion — the standard processor envelope MUST NOT leak
        # back into this code path.
        assert "success" not in body
        assert "meta" not in body

    def test_missing_message_returns_jsonrpc_envelope(self) -> None:
        from src.api import a2a_routes

        request_id = "req-missing-msg"
        agent_id = uuid.uuid4()
        request = AsyncMock(spec=Request)

        response = asyncio.run(
            a2a_routes.handle_message_send(
                agent_id=agent_id,
                params={},  # no "message" key → triggers the validation branch
                request_id=request_id,
                request=request,
                db=None,
            )
        )

        body = self._read_body(response)
        assert body["jsonrpc"] == "2.0"
        assert body["id"] == request_id
        assert body["error"]["code"] == -32602
        assert body["error"]["data"]["missing"] == "message"
        assert "success" not in body
