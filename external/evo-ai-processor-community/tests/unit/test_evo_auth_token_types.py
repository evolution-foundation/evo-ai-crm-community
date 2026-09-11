"""Authentication tests for the token shapes evo-auth actually returns.

evo-auth serializes an OAuth/bearer token with the field ``access_token`` and an
API access token with the field ``token`` (see ``TokenSerializer`` in
evo-auth-service). Both must authenticate against the processor. EVO-2123.
"""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient
from pydantic import ValidationError

from src.api.chat_routes import get_jwt_token_ws
from src.middleware.evo_auth import EvoAuthMiddleware
from src.schemas.auth import EvoAuthResponse, TokenInfo
from src.services.evo_auth_service import EvoAuthService

AGENT_ID = "11111111-1111-1111-1111-111111111111"
SESSION_ID = f"display1_{AGENT_ID}"

USER_PAYLOAD = {
    "id": "8a7c6792-0000-0000-0000-000000000001",
    "name": "Test User",
    "email": "test@example.com",
}
ACCOUNTS_PAYLOAD = [
    {
        "id": "acc-1",
        "name": "Test Account",
        "status": "active",
        "locale": "pt_BR",
    }
]

# Exactly what evo-auth returns for an api_access_token (TokenSerializer.access_token)
API_ACCESS_TOKEN_PAYLOAD = {
    "user": USER_PAYLOAD,
    "accounts": ACCOUNTS_PAYLOAD,
    "token": {
        "id": "8a7c6792-0000-0000-0000-000000000002",
        "name": "meu-token",
        "token": "90c737e950aabbccdd",
        "scopes": '["*"]',
        "expires_at": None,
        "created_at": "2026-07-13T00:00:00Z",
        "type": "api_access_token",
    },
}

# Exactly what evo-auth returns for a bearer token (TokenSerializer.oauth)
BEARER_PAYLOAD = {
    "user": USER_PAYLOAD,
    "accounts": ACCOUNTS_PAYLOAD,
    "token": {
        "access_token": "bearer-token-value",
        "expires_in": 7200,
        "refresh_token": "refresh-value",
        "created_at": "2026-07-13T00:00:00Z",
        "scopes": ["public"],
        "type": "bearer",
    },
}


def build_client(auth_response):
    """FastAPI app guarded by EvoAuthMiddleware, with evo-auth stubbed out."""
    app = FastAPI()

    @app.get("/api/v1/sessions/{session_id}/events")
    async def events(session_id: str, request: Request):
        return {"token_info": request.state.user_context["token_info"]}

    # The route the CRM calls with X-API-Key (session_sync_service.rb)
    @app.post("/api/v1/sessions/sync/{session_id}")
    async def sync(session_id: str, request: Request):
        return {"token_info": request.state.user_context["token_info"]}

    app.add_middleware(EvoAuthMiddleware)

    auth_service = MagicMock()
    auth_service.validate_token = AsyncMock(return_value=auth_response)
    return TestClient(app), auth_service


class TestTokenInfoSchema:
    def test_parses_api_access_token_field_name(self):
        """evo-auth names the api_access_token field `token`, not `access_token`."""
        info = TokenInfo(**API_ACCESS_TOKEN_PAYLOAD["token"])

        assert info.access_token == "90c737e950aabbccdd"
        assert info.type == "api_access_token"

    def test_parses_bearer_field_name(self):
        info = TokenInfo(**BEARER_PAYLOAD["token"])

        assert info.access_token == "bearer-token-value"
        assert info.type == "bearer"

    def test_dict_exposes_access_token_for_downstream_consumers(self):
        """permission_service and contextutils read token_info['access_token']."""
        response = EvoAuthResponse(**API_ACCESS_TOKEN_PAYLOAD)

        assert response.token.dict()["access_token"] == "90c737e950aabbccdd"

    def test_rejects_token_without_any_value(self):
        with pytest.raises(ValidationError):
            TokenInfo(type="api_access_token")


class TestMiddlewareTokenTypes:
    def test_api_access_token_authenticates(self):
        """AC1: a valid api_access_token returns 200, not 401."""
        auth_response = EvoAuthResponse(**API_ACCESS_TOKEN_PAYLOAD)
        client, auth_service = build_client(auth_response)

        with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_service):
            response = client.get(
                f"/api/v1/sessions/{SESSION_ID}/events",
                headers={"api_access_token": "90c737e950aabbccdd"},
            )

        assert response.status_code == 200
        token_info = response.json()["token_info"]
        assert token_info["access_token"] == "90c737e950aabbccdd"
        assert token_info["type"] == "api_access_token"

    def test_bearer_still_authenticates(self):
        """AC2: the browser app path keeps working."""
        auth_response = EvoAuthResponse(**BEARER_PAYLOAD)
        client, auth_service = build_client(auth_response)

        with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_service):
            response = client.get(
                f"/api/v1/sessions/{SESSION_ID}/events",
                headers={"Authorization": "Bearer bearer-token-value"},
            )

        assert response.status_code == 200
        assert response.json()["token_info"]["type"] == "bearer"

    def test_invalid_token_is_unauthorized(self):
        client, auth_service = build_client(None)

        with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_service), patch(
            "src.middleware.evo_auth.get_db"
        ) as get_db, patch(
            "src.middleware.evo_auth.agent_service.validate_agent_api_key",
            AsyncMock(return_value=None),
        ):
            get_db.return_value = iter([MagicMock()])
            response = client.get(
                f"/api/v1/sessions/{SESSION_ID}/events",
                headers={"api_access_token": "bogus"},
            )

        assert response.status_code == 401


class TestAgentApiKeyPath:
    def test_agent_api_key_authenticates_when_evo_auth_rejects_token(self):
        """Fallback path: a key evo-auth does not know is tried against the agent.

        This is NOT the path the CRM uses — see TestAgentApiKeySyncPath for that.
        """
        client, auth_service = build_client(None)

        with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_service), patch(
            "src.middleware.evo_auth.get_db"
        ) as get_db, patch(
            "src.middleware.evo_auth.agent_service.validate_agent_api_key",
            AsyncMock(return_value={"valid": True, "agent_id": AGENT_ID, "agent_name": "bot"}),
        ):
            get_db.return_value = iter([MagicMock()])
            response = client.get(
                f"/api/v1/sessions/{SESSION_ID}/events",
                headers={"api_access_token": "agent-api-key"},
            )

        assert response.status_code == 200
        token_info = response.json()["token_info"]
        assert token_info["access_token"] == "agent-api-key"
        assert token_info["type"] == "agent_api_key"


class TestAgentApiKeySyncPath:
    def test_x_api_key_authenticates_on_sync_route(self):
        """AC3: the CRM authenticates agent bots with X-API-Key on /sync/ routes.

        session_sync_service.rb:308 sends the agent's own key in X-API-Key; the
        middleware short-circuits before evo-auth is ever consulted.
        """
        client, auth_service = build_client(None)

        with patch(
            "src.middleware.evo_auth.get_auth_service", return_value=auth_service
        ) as get_auth, patch("src.middleware.evo_auth.get_db") as get_db, patch(
            "src.middleware.evo_auth.agent_service.validate_agent_api_key",
            AsyncMock(return_value={"valid": True, "agent_id": AGENT_ID, "agent_name": "bot"}),
        ):
            get_db.return_value = iter([MagicMock()])
            response = client.post(
                f"/api/v1/sessions/sync/{SESSION_ID}",
                headers={"X-API-Key": "agent-api-key"},
            )

        assert response.status_code == 200
        assert response.json()["token_info"] == {
            "access_token": "agent-api-key",
            "type": "agent_api_key",
        }
        get_auth.assert_not_called()

    def test_sync_route_without_any_credential_is_unauthorized(self):
        client, _ = build_client(None)

        response = client.post(f"/api/v1/sessions/sync/{SESSION_ID}")

        assert response.status_code == 401


class TestWebSocketTokenTypes:
    """The WS handshake bypasses the HTTP middleware and authenticates on its own."""

    @staticmethod
    def _auth_service(valid_for):
        service = MagicMock()

        async def validate(token, token_type):
            if token_type != valid_for:
                return None
            payload = (
                API_ACCESS_TOKEN_PAYLOAD if valid_for == "api_access_token" else BEARER_PAYLOAD
            )
            return EvoAuthResponse(**payload)

        service.validate_token = AsyncMock(side_effect=validate)
        return service

    @pytest.mark.asyncio
    async def test_ws_accepts_api_access_token(self):
        """AC1 on the WS surface: evo-auth types by header, so both are probed."""
        service = self._auth_service("api_access_token")

        with patch("src.services.evo_auth_service.get_auth_service", return_value=service):
            payload = await get_jwt_token_ws("90c737e950aabbccdd", True)

        assert payload is not None
        assert payload["user_id"] == USER_PAYLOAD["id"]
        assert [call.args[1] for call in service.validate_token.await_args_list] == [
            "bearer",
            "api_access_token",
        ]

    @pytest.mark.asyncio
    async def test_ws_bearer_does_not_pay_for_the_second_probe(self):
        service = self._auth_service("bearer")

        with patch("src.services.evo_auth_service.get_auth_service", return_value=service):
            payload = await get_jwt_token_ws("bearer-token-value", True)

        assert payload is not None
        assert service.validate_token.await_count == 1

    @pytest.mark.asyncio
    async def test_ws_rejects_a_token_evo_auth_does_not_know(self):
        service = self._auth_service("nothing-is-valid")

        with patch("src.services.evo_auth_service.get_auth_service", return_value=service):
            payload = await get_jwt_token_ws("bogus", True)

        assert payload is None


class TestCredentialSafeLogging:
    @pytest.mark.asyncio
    async def test_unparseable_payload_never_logs_the_token(self):
        """A shape drift must be diagnosable from the logs without leaking the token."""
        secret = "90c737e950aabbccdd"
        drifted = {
            "success": True,
            "data": {
                "user": USER_PAYLOAD,
                "accounts": ACCOUNTS_PAYLOAD,
                "token": {"renamed_again": secret, "type": "api_access_token"},
            },
        }
        service = EvoAuthService()

        with patch.object(service, "_post_request", AsyncMock(return_value=drifted)), patch(
            "src.services.evo_auth_service.logger"
        ) as logger:
            result = await service.validate_token(secret, "api_access_token")

        assert result is None
        logged = " ".join(str(call) for call in logger.error.call_args_list)
        assert secret not in logged
        assert "renamed_again" in logged  # the field names still reach the logs


class TestMiddlewareErrorReporting:
    def test_unexpected_error_logs_traceback(self):
        """The 503 must not swallow the real cause (EVO-2123, adjacent bug)."""
        client, auth_service = build_client(None)
        auth_service.validate_token = AsyncMock(side_effect=RuntimeError("boom"))

        with patch("src.middleware.evo_auth.get_auth_service", return_value=auth_service), patch(
            "src.middleware.evo_auth.logger"
        ) as logger:
            response = client.get(
                f"/api/v1/sessions/{SESSION_ID}/events",
                headers={"Authorization": "Bearer whatever"},
            )

        assert response.status_code == 503
        logger.error.assert_called_once()
        assert logger.error.call_args.kwargs.get("exc_info") is True
