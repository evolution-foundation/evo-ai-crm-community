"""Object-level authorization for agents.

The Community box is single-tenant (agents have no owner column), so the
object boundary enforced here is: agent-bot credentials act only on their own
agent, a missing user context fails closed, regular users keep pool access
(flagged as shared when granted via folder share), and a bot token only
bypasses route RBAC on paths scoped to its own agent.
"""

from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from src.api.dependencies import verify_agent_access
from src.services.permission_service import PermissionService

AGENT_ID = "11111111-1111-1111-1111-111111111111"
OTHER_AGENT_ID = "22222222-2222-2222-2222-222222222222"


def make_agent(agent_id=AGENT_ID, folder_id=None):
    return SimpleNamespace(id=agent_id, folder_id=folder_id)


def run(coro):
    return asyncio.run(coro)


class TestVerifyAgentAccess:
    def test_missing_user_context_fails_closed(self):
        with pytest.raises(HTTPException) as exc:
            run(verify_agent_access(MagicMock(), make_agent(), "read", None))
        assert exc.value.status_code == 403

    def test_agent_bot_can_access_its_own_agent(self):
        context = {"is_agent_bot": True, "agent_id": AGENT_ID}
        has_access, is_shared = run(
            verify_agent_access(MagicMock(), make_agent(AGENT_ID), "read", context)
        )
        assert has_access is True
        assert is_shared is False

    def test_agent_bot_is_denied_on_another_agent(self):
        context = {"is_agent_bot": True, "agent_id": AGENT_ID}
        with pytest.raises(HTTPException) as exc:
            run(verify_agent_access(MagicMock(), make_agent(OTHER_AGENT_ID), "write", context))
        assert exc.value.status_code == 403

    def test_agent_bot_without_agent_id_is_denied(self):
        context = {"is_agent_bot": True}
        with pytest.raises(HTTPException) as exc:
            run(verify_agent_access(MagicMock(), make_agent(), "read", context))
        assert exc.value.status_code == 403

    def test_user_has_pool_access_without_folder(self):
        context = {"is_agent_bot": False, "email": "user@example.com"}
        has_access, is_shared = run(
            verify_agent_access(MagicMock(), make_agent(), "read", context)
        )
        assert has_access is True
        assert is_shared is False

    def test_user_access_is_flagged_shared_via_folder_share(self):
        context = {"is_agent_bot": False, "email": "user@example.com"}
        agent = make_agent(folder_id="33333333-3333-3333-3333-333333333333")
        with patch(
            "src.api.dependencies.folder_share_service.check_folder_access", return_value=True
        ):
            has_access, is_shared = run(verify_agent_access(MagicMock(), agent, "read", context))
        assert has_access is True
        assert is_shared is True

    def test_folder_share_lookup_failure_keeps_pool_access(self):
        context = {"is_agent_bot": False, "email": "user@example.com"}
        agent = make_agent(folder_id="33333333-3333-3333-3333-333333333333")
        with patch(
            "src.api.dependencies.folder_share_service.check_folder_access",
            side_effect=RuntimeError("db down"),
        ):
            has_access, is_shared = run(verify_agent_access(MagicMock(), agent, "read", context))
        assert has_access is True
        assert is_shared is False

    def test_folder_share_explicit_denial_fails_closed(self):
        # An explicit HTTPException from the share service must propagate as a
        # denial, not be swallowed into a silent grant.
        context = {"is_agent_bot": False, "email": "user@example.com"}
        agent = make_agent(folder_id="33333333-3333-3333-3333-333333333333")
        with patch(
            "src.api.dependencies.folder_share_service.check_folder_access",
            side_effect=HTTPException(status_code=403, detail="denied"),
        ):
            with pytest.raises(HTTPException) as exc:
                run(verify_agent_access(MagicMock(), agent, "read", context))
        assert exc.value.status_code == 403


class TestAgentBotPermissionScope:
    def make_service(self):
        with patch("src.services.permission_service.EvoAuthService"):
            return PermissionService("http://auth.test")

    def make_request(self, path, context):
        request = MagicMock()
        request.state.user_context = context
        request.url.path = path
        return request

    def test_path_scoped_to_agent_matches_segment_and_session_suffix(self):
        assert PermissionService._path_scoped_to_agent(
            f"/api/v1/agents/{AGENT_ID}/integrations/github/status", AGENT_ID
        )
        assert PermissionService._path_scoped_to_agent(f"/api/v1/chat/{AGENT_ID}", AGENT_ID)
        assert PermissionService._path_scoped_to_agent(
            f"/api/v1/sessions/sync/display_{AGENT_ID}", AGENT_ID
        )
        assert not PermissionService._path_scoped_to_agent("/api/v1/clients/usage", AGENT_ID)
        assert not PermissionService._path_scoped_to_agent(
            f"/api/v1/agents/{OTHER_AGENT_ID}/integrations/github/status", AGENT_ID
        )

    def test_path_scoped_rejects_mid_token_substring(self):
        # The agent id embedded inside a larger token must not be treated as
        # scope (canonical segment extraction, not substring matching).
        assert not PermissionService._path_scoped_to_agent(
            f"/api/v1/sessions/sync/prefix_{AGENT_ID}_suffix", AGENT_ID
        )
        assert not PermissionService._path_scoped_to_agent(
            f"/api/v1/agents/x{AGENT_ID}x/status", AGENT_ID
        )
        assert not PermissionService._path_scoped_to_agent("/api/v1/agents//status", "")

    def test_bot_bypasses_rbac_for_runtime_action_on_its_own_agent(self):
        service = self.make_service()
        context = {"is_agent_bot": True, "agent_id": AGENT_ID, "token_info": {}}

        request = self.make_request(f"/api/v1/a2a/{AGENT_ID}", context)
        assert run(service.validate_permission(request, "ai_a2a_protocol", "execute")) is None

    def test_bot_denied_credential_read_on_its_own_agent(self):
        # Reading integration config exposes OAuth credentials; a runtime bot
        # key must not reach it even on its own agent.
        service = self.make_service()
        context = {"is_agent_bot": True, "agent_id": AGENT_ID, "token_info": {}}

        request = self.make_request(f"/api/v1/agents/{AGENT_ID}/integrations/github/status", context)
        with pytest.raises(HTTPException) as exc:
            run(service.validate_permission(request, "integrations", "read"))
        assert exc.value.status_code == 403

    def test_bot_denied_management_action_on_its_own_agent(self):
        # Disconnecting an integration writes/destroys credentials — a
        # management action outside the runtime allowlist.
        service = self.make_service()
        context = {"is_agent_bot": True, "agent_id": AGENT_ID, "token_info": {}}

        request = self.make_request(f"/api/v1/agents/{AGENT_ID}/integrations/github", context)
        with pytest.raises(HTTPException) as exc:
            run(service.validate_permission(request, "integrations", "disconnect"))
        assert exc.value.status_code == 403

    def test_bot_is_denied_rbac_bypass_on_unscoped_path(self):
        service = self.make_service()
        context = {"is_agent_bot": True, "agent_id": AGENT_ID, "token_info": {}}

        request = self.make_request("/api/v1/clients/usage", context)
        with pytest.raises(HTTPException) as exc:
            run(service.validate_permission(request, "ai_clients", "usage"))
        assert exc.value.status_code == 403

    def test_bot_is_denied_any_action_on_another_agents_integration_route(self):
        # P1 confinement on an integration router: a bot key for agent A cannot
        # act on agent B, for a runtime action or a management action.
        service = self.make_service()
        context = {"is_agent_bot": True, "agent_id": AGENT_ID, "token_info": {}}

        read_request = self.make_request(
            f"/api/v1/agents/{OTHER_AGENT_ID}/integrations/github/status", context
        )
        with pytest.raises(HTTPException) as exc:
            run(service.validate_permission(read_request, "integrations", "read"))
        assert exc.value.status_code == 403

        disconnect_request = self.make_request(
            f"/api/v1/agents/{OTHER_AGENT_ID}/integrations/github", context
        )
        with pytest.raises(HTTPException) as exc:
            run(service.validate_permission(disconnect_request, "integrations", "disconnect"))
        assert exc.value.status_code == 403


class TestUserPermissionOnIntegrationWrites:
    """A regular user without the granted key is denied on gated routes —
    the 403 path RequirePermission enforces on the integration credential
    writes (save credentials / connect / disconnect)."""

    def make_service(self):
        with patch("src.services.permission_service.EvoAuthService"):
            service = PermissionService("http://auth.test")
        return service

    def make_request(self, context):
        request = MagicMock()
        request.state.user_context = context
        request.url.path = f"/api/v1/agents/{AGENT_ID}/integrations/github/credentials"
        return request

    def user_context(self):
        return {
            "is_agent_bot": False,
            "user_id": "u-1",
            "token_info": {"access_token": "tok", "type": "bearer"},
        }

    def test_user_without_permission_gets_403(self):
        from unittest.mock import AsyncMock

        service = self.make_service()
        service.evo_auth_service.check_permission = AsyncMock(return_value=False)

        with pytest.raises(HTTPException) as exc:
            run(service.validate_permission(self.make_request(self.user_context()), "integrations", "update"))
        assert exc.value.status_code == 403
        assert exc.value.detail["permission"] == "integrations.update"

    def test_user_with_permission_passes(self):
        from unittest.mock import AsyncMock

        service = self.make_service()
        service.evo_auth_service.check_permission = AsyncMock(return_value=True)

        assert run(service.validate_permission(self.make_request(self.user_context()), "integrations", "update")) is None


RUNTIME_PERMISSION = "ai_agent_processor.execute"


class TestIsAgentBotPermissionAllowed:
    """Shared confinement decision reused by the WebSocket handshake."""

    def test_bot_allowed_runtime_on_own_agent(self):
        context = {"is_agent_bot": True, "agent_id": AGENT_ID}
        assert PermissionService.is_agent_bot_permission_allowed(
            context, f"/chat/ws/{AGENT_ID}/user/sess", RUNTIME_PERMISSION
        )

    def test_bot_denied_on_another_agent(self):
        context = {"is_agent_bot": True, "agent_id": OTHER_AGENT_ID}
        assert not PermissionService.is_agent_bot_permission_allowed(
            context, f"/chat/ws/{AGENT_ID}/user/sess", RUNTIME_PERMISSION
        )

    def test_bot_denied_non_runtime_on_own_agent(self):
        context = {"is_agent_bot": True, "agent_id": AGENT_ID}
        assert not PermissionService.is_agent_bot_permission_allowed(
            context, f"/agents/{AGENT_ID}/integrations/github", "integrations.disconnect"
        )

    def test_bot_without_agent_id_denied(self):
        context = {"is_agent_bot": True}
        assert not PermissionService.is_agent_bot_permission_allowed(
            context, f"/chat/ws/{AGENT_ID}/user/sess", RUNTIME_PERMISSION
        )

    def test_regular_user_unaffected(self):
        assert PermissionService.is_agent_bot_permission_allowed(
            {"is_agent_bot": False}, f"/chat/ws/{OTHER_AGENT_ID}/user/sess", RUNTIME_PERMISSION
        )
        assert PermissionService.is_agent_bot_permission_allowed(
            None, f"/chat/ws/{OTHER_AGENT_ID}/user/sess", RUNTIME_PERMISSION
        )


class TestChatWebSocketAgentBotConfinement:
    """The chat WebSocket routes bypass the HTTP RequirePermission gate, so the
    agent-bot confinement is enforced inline at the handshake."""

    def build_client(self, monkeypatch, bot_agent_id):
        import src.api.chat_routes as chat_routes
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        from src.config.database import get_db

        fake_agent = SimpleNamespace(id=AGENT_ID, name="agent-a", folder_id=None, config=None)
        monkeypatch.setattr(
            chat_routes.agent_service, "get_agent", AsyncMock(return_value=fake_agent)
        )
        monkeypatch.setattr(
            chat_routes,
            "get_jwt_token_ws",
            AsyncMock(return_value={
                "is_agent_bot": True,
                "agent_id": bot_agent_id,
                "user_id": "bot",
            }),
        )

        async def fake_stream(**kwargs):
            yield json.dumps({"reply": "ok"})

        monkeypatch.setattr(chat_routes, "run_agent_stream", fake_stream)

        app = FastAPI()
        app.include_router(chat_routes.router)
        app.dependency_overrides[get_db] = lambda: None
        return TestClient(app)

    def test_bot_for_other_agent_rejected_at_handshake(self, monkeypatch):
        from starlette.websockets import WebSocketDisconnect

        client = self.build_client(monkeypatch, bot_agent_id=OTHER_AGENT_ID)
        with client.websocket_connect(f"/chat/ws/{AGENT_ID}/user/sess") as ws:
            ws.send_json({"type": "authorization", "token": "t"})
            with pytest.raises(WebSocketDisconnect) as exc:
                ws.receive_json()
        assert exc.value.code == 1008

    def test_bot_for_own_agent_accepted_and_runs(self, monkeypatch):
        client = self.build_client(monkeypatch, bot_agent_id=AGENT_ID)
        with client.websocket_connect(f"/chat/ws/{AGENT_ID}/user/sess") as ws:
            ws.send_json({"type": "authorization", "token": "t"})
            ws.send_json({"message": "hi"})
            first = ws.receive_json()
        assert first["turn_complete"] is False
        assert first["message"] == {"reply": "ok"}
