"""EVO-2103 — Regression tests for the "testar agente" panel cross-user leak.

The ADK indexes sessions by (agent_id, user_id, session_id). Before this fix:

  1. `GET /sessions/agent/{id}` returned every session for the agent, so a
     user's test panel listed WhatsApp/production conversations owned by other
     users (contact_ids). Clicking one showed real customer messages.
  2. `POST /chat/{agent_id}/{session_id}` looked the session up in the ADK with
     the logged user's id. If the session was originally stored by another
     owner, the ADK missed → 500 "Session not found" (with a double-wrap).
  3. `GET /sessions/{id}/messages` returned 200 with the content of sessions
     owned by other users — real customer conversations leaked to any logged
     user on the same instance.

The 500 in (2) is what currently keeps a user out of someone else's session, so
resolving the ADK key from the owner cannot stand alone: it has to come with an
ownership gate, otherwise chatting into a real customer conversation stops
failing and starts working (the agent answers with the owner's history as
context, and its events are appended to the customer's conversation). Every
session-scoped route therefore resolves the caller the same way and denies on an
owner mismatch — with agent-bot credentials exempt, since the CRM legitimately
syncs and deletes the sessions of real conversations, which are owned by the
contact.

These tests exercise the handler functions directly (no FastAPI TestClient
needed) with mocked deps so we lock the behavior at the code level and
survive future refactors.
"""

from __future__ import annotations

import asyncio
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.api import chat_routes, session_routes
from src.services import session_service as session_service_module


AGENT_ID = uuid.UUID("11111111-1111-1111-1111-111111111111")
OTHER_AGENT_ID = uuid.UUID("22222222-2222-2222-2222-222222222222")
SESSION_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OWNER_USER_ID = "owner-user@example.com"
LOGGED_USER_ID = "another-user@example.com"
CONTACT_ID = "5511999999999"


def run(coro):
    return asyncio.run(coro)


def _make_request():
    """error_response() feeds request.method/url.path into a Pydantic model, so
    MagicMock defaults would fail validation. Give it real strings."""
    request = MagicMock()
    request.method = "GET"
    request.url = SimpleNamespace(path=f"/sessions/{SESSION_ID}")
    return request


def _human(user_id):
    return {"user_id": user_id, "email": user_id, "is_agent_bot": False}


def _agent_bot():
    """Agent-bot context as built by EvoAuthMiddleware: no user_id, no email."""
    return {"agent_id": str(AGENT_ID), "agent_name": "bot", "is_agent_bot": True}


def _make_db_session(owner_user_id=OWNER_USER_ID, session_id=SESSION_ID, app_name=None):
    """Simulate a SessionModel row returned by db.query(...).filter(...).first()."""
    return SimpleNamespace(
        id=session_id,
        user_id=owner_user_id,
        app_name=app_name or str(AGENT_ID),
    )


def _make_db_with_session(session_row):
    """Return a mocked SQLAlchemy `db` whose query chain resolves to `session_row`."""
    db = MagicMock()
    db.query.return_value.filter.return_value.first.return_value = session_row
    return db


def _call_chat(db, current_user, mock_run):
    payload = SimpleNamespace(message="oi", files=None)
    with patch("src.api.chat_routes.run_agent_adk", new=mock_run):
        return run(
            chat_routes.chat(
                payload=payload,
                agent_id=str(AGENT_ID),
                session_id=SESSION_ID,
                request=_make_request(),
                current_user=current_user,
                db=db,
                _=None,
            )
        )


# -----------------------------------------------------------------------------
# AC2 — POST /chat/{agent_id}/{session_id} must use the DB session owner as the
#       ADK user_id lookup key, and must refuse sessions owned by someone else.
# -----------------------------------------------------------------------------
class TestChatUsesSessionOwnerNotLoggedUser:
    def test_chat_passes_owner_id_as_adk_lookup_key(self):
        db = _make_db_with_session(_make_db_session(owner_user_id=OWNER_USER_ID))
        mock_run = AsyncMock(return_value={"final_response": "hello", "message_history": []})

        _call_chat(db, _human(OWNER_USER_ID), mock_run)

        assert mock_run.await_count == 1
        called_args, called_kwargs = mock_run.call_args
        # run_agent(agent_id, external_id, message, ...) — the ADK lookup key is
        # the `user_id` kwarg, and external_id (2nd positional) keeps the artifact
        # namespace stable. Both must be the session owner.
        assert called_kwargs.get("user_id") == OWNER_USER_ID
        assert called_args[1] == OWNER_USER_ID

    def test_chat_denies_session_owned_by_another_user(self):
        """The whole point of EVO-2103: resolving the owner as the ADK key makes
        cross-user chat WORK unless ownership is enforced. It must 403, and the
        agent must never run inside the other owner's session."""
        db = _make_db_with_session(_make_db_session(owner_user_id=OWNER_USER_ID))
        mock_run = AsyncMock(return_value={"final_response": "leak", "message_history": []})

        response = _call_chat(db, _human(LOGGED_USER_ID), mock_run)

        assert mock_run.await_count == 0, (
            "the agent ran inside a session owned by another user — EVO-2103 "
            "cross-user regression"
        )
        assert response.status_code == 403

    def test_chat_allows_agent_bot_on_contact_owned_session(self):
        """Real conversations are owned by the contact, and the CRM drives them
        with an agent-bot key. The ownership gate must not break that."""
        db = _make_db_with_session(_make_db_session(owner_user_id=CONTACT_ID))
        mock_run = AsyncMock(return_value={"final_response": "ok", "message_history": []})

        _call_chat(db, _agent_bot(), mock_run)

        assert mock_run.await_count == 1
        _args, called_kwargs = mock_run.call_args
        assert called_kwargs.get("user_id") == CONTACT_ID

    def test_chat_falls_back_to_logged_user_when_session_missing(self):
        """First-message-no-session flow: session row absent in DB. Backward
        compat — do not break existing bootstrap paths."""
        db = _make_db_with_session(None)
        mock_run = AsyncMock(return_value={"final_response": "hi", "message_history": []})

        _call_chat(db, _human(LOGGED_USER_ID), mock_run)

        assert mock_run.await_count == 1
        called_args, called_kwargs = mock_run.call_args
        assert called_kwargs.get("user_id") == LOGGED_USER_ID
        assert called_args[1] == LOGGED_USER_ID

    def test_chat_scopes_session_lookup_to_the_agent_in_the_url(self):
        """Session ids are unique per (app_name, user_id, id) in the ADK, so the
        row must be fetched for the agent in the path — not by id alone."""
        db = _make_db_with_session(_make_db_session(owner_user_id=OWNER_USER_ID))
        mock_run = AsyncMock(return_value={"final_response": "hello", "message_history": []})

        _call_chat(db, _human(OWNER_USER_ID), mock_run)

        filter_args, _kwargs = db.query.return_value.filter.call_args
        assert len(filter_args) == 2, (
            "chat looked the session up by id alone; it must also filter by "
            "app_name == agent_id"
        )


# -----------------------------------------------------------------------------
# AC1 — GET /sessions/agent/{agent_id} must scope to the logged user.
# -----------------------------------------------------------------------------
class TestListSessionsScopedToLoggedUser:
    def _call_list(self, current_user, mock_list):
        with patch(
            "src.api.session_routes.agent_service.get_agent",
            new=AsyncMock(return_value=SimpleNamespace(id=str(AGENT_ID), folder_id=None)),
        ), patch(
            "src.api.session_routes.verify_agent_access",
            new=AsyncMock(return_value=(True, False)),
        ), patch(
            "src.api.session_routes.get_sessions_by_agent", new=mock_list
        ), patch(
            "src.api.session_routes.get_session_metadata", return_value=None
        ):
            return run(
                session_routes.get_agent_sessions(
                    request=_make_request(),
                    agent_id=AGENT_ID,
                    current_user=current_user,
                    _=None,
                    db=MagicMock(),
                )
            )

    def test_list_by_agent_filters_by_current_user_id(self):
        mock_list = AsyncMock(return_value=[])

        self._call_list(_human(LOGGED_USER_ID), mock_list)

        assert mock_list.await_count == 1
        _args, kwargs = mock_list.call_args
        assert kwargs.get("user_id") == LOGGED_USER_ID, (
            f"get_agent_sessions must pass the logged user as the user_id "
            f"filter to prevent cross-user leak — EVO-2103 regression. Got "
            f"user_id={kwargs.get('user_id')!r}."
        )

    def test_list_denies_when_identity_cannot_be_resolved(self):
        """An unresolvable identity must deny, never degrade into "no filter" —
        get_sessions_by_agent treats a falsy user_id as "return everything"."""
        mock_list = AsyncMock(return_value=[])

        response = self._call_list({"is_agent_bot": False}, mock_list)

        assert mock_list.await_count == 0
        assert response.status_code == 403


# -----------------------------------------------------------------------------
# AC1 (sibling endpoint) — GET /sessions/account listed every session of every
# accessible agent, which leaked the same conversations (and their session ids).
# -----------------------------------------------------------------------------
class TestAccountSessionsScopedToLoggedUser:
    def test_get_sessions_by_account_propagates_the_user_filter(self):
        mock_by_agent = AsyncMock(return_value=[])

        with patch(
            "src.services.agent_service.get_accessible_agents_for_account",
            return_value=[SimpleNamespace(id=str(AGENT_ID))],
        ), patch.object(
            session_service_module, "get_sessions_by_agent", new=mock_by_agent
        ):
            run(
                session_service_module.get_sessions_by_account(
                    MagicMock(), LOGGED_USER_ID, LOGGED_USER_ID
                )
            )

        assert mock_by_agent.await_count == 1
        _args, kwargs = mock_by_agent.call_args
        assert kwargs.get("user_id") == LOGGED_USER_ID, (
            "/sessions/account must be owner-scoped like /sessions/agent/{id}"
        )


# -----------------------------------------------------------------------------
# The owner filter must fail CLOSED: an empty identity filters to nothing.
# -----------------------------------------------------------------------------
class TestSessionFilterFailsClosed:
    def _owner_filter_calls(self, user_id):
        """The agent filter is applied on db.query(...); the owner filter is the
        second .filter(), chained onto its result."""
        db = MagicMock()
        run(session_service_module.get_sessions_by_agent(db, AGENT_ID, user_id=user_id))
        return db.query.return_value.filter.return_value.filter.call_count

    def test_empty_user_id_still_filters(self):
        assert self._owner_filter_calls("") == 1, (
            "an empty user_id widened the query back to every session of the "
            "agent — the filter must fail closed"
        )

    def test_none_user_id_opts_out_of_the_filter(self):
        assert self._owner_filter_calls(None) == 0


# -----------------------------------------------------------------------------
# AC3 — GET /sessions/{id}/messages must return 403 when session belongs to
#       another owner (LGPD: no customer conversation leaks between users).
# -----------------------------------------------------------------------------
class TestGetMessagesBlocksCrossUserRead:
    def _run_get_messages(self, session_user_id, current_user):
        fake_session = SimpleNamespace(
            id=SESSION_ID,
            user_id=session_user_id,
            app_name=str(AGENT_ID),
        )

        with patch(
            "src.api.session_routes.get_session_by_id",
            new=AsyncMock(return_value=fake_session),
        ), patch(
            "src.api.session_routes.agent_service.get_agent",
            new=AsyncMock(return_value=SimpleNamespace(id=str(AGENT_ID), folder_id=None)),
        ), patch(
            "src.api.session_routes.verify_agent_access",
            new=AsyncMock(return_value=(True, False)),
        ), patch(
            "src.api.session_routes.get_session_events",
            new=AsyncMock(return_value=[]),
        ):
            return run(
                session_routes.get_agent_messages(
                    request=_make_request(),
                    session_id=SESSION_ID,
                    current_user=current_user,
                    _=None,
                    db=MagicMock(),
                )
            )

    def test_returns_403_when_session_belongs_to_another_user(self):
        response = self._run_get_messages(OWNER_USER_ID, _human(LOGGED_USER_ID))
        assert response.status_code == 403

    def test_returns_200_for_own_session(self):
        response = self._run_get_messages(OWNER_USER_ID, _human(OWNER_USER_ID))
        assert response.status_code == 200

    def test_agent_bot_may_read_contact_owned_session(self):
        response = self._run_get_messages(CONTACT_ID, _agent_bot())
        assert response.status_code == 200


# -----------------------------------------------------------------------------
# Deleting someone else's conversation is the destructive twin of reading it:
# agent access is pool-wide on the single-tenant box, so only ownership stops it.
# -----------------------------------------------------------------------------
class TestDeleteSessionRequiresOwnership:
    def _run_delete(self, session_user_id, current_user, mock_delete):
        fake_session = SimpleNamespace(
            id=SESSION_ID,
            user_id=session_user_id,
            app_name=str(AGENT_ID),
        )

        with patch(
            "src.api.session_routes.get_session_by_id",
            new=AsyncMock(return_value=fake_session),
        ), patch(
            "src.api.session_routes.agent_service.get_agent",
            new=AsyncMock(return_value=SimpleNamespace(id=str(AGENT_ID), folder_id=None)),
        ), patch(
            "src.api.session_routes.verify_agent_access",
            new=AsyncMock(return_value=(True, False)),
        ), patch(
            "src.api.session_routes.delete_session", new=mock_delete
        ):
            return run(
                session_routes.remove_session(
                    request=_make_request(),
                    session_id=SESSION_ID,
                    current_user=current_user,
                    _=None,
                    db=MagicMock(),
                )
            )

    def test_denies_delete_of_another_users_session(self):
        mock_delete = AsyncMock()

        response = self._run_delete(OWNER_USER_ID, _human(LOGGED_USER_ID), mock_delete)

        assert mock_delete.await_count == 0, (
            "a user deleted the session of a conversation owned by someone else"
        )
        assert response.status_code == 403

    def test_allows_delete_of_own_session(self):
        mock_delete = AsyncMock()

        self._run_delete(OWNER_USER_ID, _human(OWNER_USER_ID), mock_delete)

        assert mock_delete.await_count == 1

    def test_allows_agent_bot_to_delete_contact_owned_session(self):
        """The CRM's DeleteSessionJob calls this route with an agent-bot key to
        clean up the sessions of real conversations."""
        mock_delete = AsyncMock()

        self._run_delete(CONTACT_ID, _agent_bot(), mock_delete)

        assert mock_delete.await_count == 1


# -----------------------------------------------------------------------------
# EVO-2124 — the /metadata trio was the hole EVO-2103 left open. It stayed shut
# only because ai_chat_sessions is an all-system resource (no checkbox in the
# role editor, so effectively admin-only). EVO-2124 re-gates these routes on
# ai_agents.{read,write}, which an admin DOES tick for an atendente — so the
# missing owner check becomes reachable and has to be closed here.
#
# GET is the real leak: get_session_metadata() queries by session_id alone.
# PUT/DELETE are scoped by created_by_user_id in the service, so they could not
# corrupt another owner's row — they are gated for uniformity (and so PUT stops
# hanging a row of your own off someone else's session).
# -----------------------------------------------------------------------------
class TestSessionMetadataRequiresOwnership:
    def _patched(self, session_user_id):
        fake_session = SimpleNamespace(
            id=SESSION_ID,
            user_id=session_user_id,
            app_name=str(AGENT_ID),
        )
        return patch(
            "src.api.session_routes.get_session_by_id",
            new=AsyncMock(return_value=fake_session),
        ), patch(
            "src.api.session_routes.agent_service.get_agent",
            new=AsyncMock(return_value=SimpleNamespace(id=str(AGENT_ID), folder_id=None)),
        ), patch(
            "src.api.session_routes.verify_agent_access",
            new=AsyncMock(return_value=(True, False)),
        )

    def _run_get(self, session_user_id, current_user, mock_get):
        p1, p2, p3 = self._patched(session_user_id)
        with p1, p2, p3, patch(
            "src.api.session_routes.get_session_metadata", new=mock_get
        ):
            return run(
                session_routes.get_session_metadata_endpoint(
                    request=_make_request(),
                    session_id=SESSION_ID,
                    current_user=current_user,
                    _=None,
                    db=MagicMock(),
                )
            )

    def _run_put(self, session_user_id, current_user, mock_update):
        p1, p2, p3 = self._patched(session_user_id)
        with p1, p2, p3, patch(
            "src.api.session_routes.update_session_metadata", new=mock_update
        ), patch(
            "src.api.session_routes.create_session_metadata",
            return_value=SimpleNamespace(
                name="n", description="d", tags=[], updated_at="2026-01-01T00:00:00"
            ),
        ):
            return run(
                session_routes.update_session_metadata_endpoint(
                    request=_make_request(),
                    session_id=SESSION_ID,
                    metadata=SimpleNamespace(name="n", description="d", tags=[]),
                    current_user=current_user,
                    _=None,
                    db=MagicMock(),
                )
            )

    def _run_delete(self, session_user_id, current_user, mock_delete):
        p1, p2, p3 = self._patched(session_user_id)
        with p1, p2, p3, patch(
            "src.api.session_routes.delete_session_metadata", new=mock_delete
        ):
            return run(
                session_routes.delete_session_metadata_endpoint(
                    request=_make_request(),
                    session_id=SESSION_ID,
                    current_user=current_user,
                    _=None,
                    db=MagicMock(),
                )
            )

    def test_get_denies_metadata_of_another_users_session(self):
        mock_get = MagicMock(return_value={"name": "Cliente João - cobrança"})

        response = self._run_get(OWNER_USER_ID, _human(LOGGED_USER_ID), mock_get)

        assert response.status_code == 403
        assert mock_get.call_count == 0, (
            "metadata of a session owned by someone else was read — the row is "
            "fetched by session_id alone, so only the owner gate stops it"
        )

    def test_get_allows_own_metadata(self):
        mock_get = MagicMock(return_value={"name": "meu teste"})

        response = self._run_get(OWNER_USER_ID, _human(OWNER_USER_ID), mock_get)

        assert response.status_code == 200
        assert mock_get.call_count == 1

    def test_get_allows_agent_bot(self):
        mock_get = MagicMock(return_value=None)

        response = self._run_get(CONTACT_ID, _agent_bot(), mock_get)

        assert response.status_code == 200

    def test_put_denies_write_on_another_users_session(self):
        mock_update = MagicMock()

        response = self._run_put(OWNER_USER_ID, _human(LOGGED_USER_ID), mock_update)

        assert response.status_code == 403
        assert mock_update.call_count == 0

    def test_put_allows_own_session(self):
        mock_update = MagicMock(
            return_value=SimpleNamespace(
                name="n", description="d", tags=[], updated_at="2026-01-01T00:00:00"
            )
        )

        response = self._run_put(OWNER_USER_ID, _human(OWNER_USER_ID), mock_update)

        assert response.status_code == 200
        assert mock_update.call_count == 1

    def test_delete_denies_on_another_users_session(self):
        mock_delete = MagicMock(return_value=True)

        response = self._run_delete(OWNER_USER_ID, _human(LOGGED_USER_ID), mock_delete)

        assert response.status_code == 403
        assert mock_delete.call_count == 0

    def test_delete_allows_own_session(self):
        mock_delete = MagicMock(return_value=True)

        response = self._run_delete(OWNER_USER_ID, _human(OWNER_USER_ID), mock_delete)

        assert response.status_code == 204
        assert mock_delete.call_count == 1
