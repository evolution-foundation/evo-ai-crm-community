"""EVO-2169: cancel_calendar_event tool.

The agent had no cancel tool, so it hallucinated cancellations. This tool searches
the window (one API call), disambiguates on multiple matches, refuses (informative
message) on zero matches, and deletes via events().delete(sendUpdates="all").
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from src.services.adk.tools.google_calendar import create_cancel_event_tool
from src.services.adk.tools.google_calendar.base import GoogleCalendarClient

AGENT_ID = "c9cbd608-ee35-49fe-8200-fadaaa682d87"

CALENDAR_CONFIG = {"settings": {"timezone": "America/Sao_Paulo", "connected": True}}

FULL_CREDS = {
    "refresh_token": "rt",
    "client_id": "cid",
    "client_secret": "sec",
    "token": "tok",
    "token_uri": "https://oauth2.googleapis.com/token",
}
SANITIZED_CREDS = {
    "connected": True,
    "email": "mcc@agencia.bid",
    "provider": "google_calendar_credentials",
    "scopes": ["https://www.googleapis.com/auth/calendar.events"],
    "token_uri": "https://oauth2.googleapis.com/token",
}


def _event(eid, summary):
    return {
        "id": eid,
        "summary": summary,
        "start": {"dateTime": "2026-07-20T15:00:00-03:00"},
        "end": {"dateTime": "2026-07-20T16:00:00-03:00"},
    }


def _mock_service():
    svc = MagicMock()
    svc.events.return_value.delete.return_value.execute.return_value = {}
    return svc


def _tool(creds=FULL_CREDS):
    return create_cancel_event_tool(
        agent_id=AGENT_ID, calendar_config=CALENDAR_CONFIG, credentials_config=creds, db=None
    )


def _run(tool, events, svc, **kwargs):
    with patch.object(GoogleCalendarClient, "get_calendar_service", return_value=svc), patch.object(
        GoogleCalendarClient,
        "check_availability",
        new=AsyncMock(return_value={"status": "success", "available": False, "events": events}),
    ):
        return asyncio.run(
            tool(start_date="2026-07-20T00:00:00", end_date="2026-07-20T23:59:59", **kwargs)
        )


def test_single_match_is_cancelled_and_notifies():
    svc = _mock_service()
    res = _run(_tool(), [_event("evt-1", "Reunião Franquia")], svc)
    assert res["status"] == "success"
    svc.events.return_value.delete.assert_called_once_with(
        calendarId="primary", eventId="evt-1", sendUpdates="all"
    )


def test_multiple_matches_ask_for_disambiguation():
    svc = _mock_service()
    res = _run(_tool(), [_event("a", "Reunião A"), _event("b", "Reunião B")], svc)
    assert res["status"] == "needs_clarification"
    assert len(res["events"]) == 2
    svc.events.return_value.delete.assert_not_called()  # never guesses


def test_no_match_returns_informative_message_no_hallucination():
    svc = _mock_service()
    res = _run(_tool(), [], svc)
    assert res["status"] == "error"
    assert "nenhuma" in res["message"].lower()
    svc.events.return_value.delete.assert_not_called()


def test_title_filter_narrows_to_one():
    svc = _mock_service()
    res = _run(_tool(), [_event("a", "Reunião A"), _event("b", "Consulta B")], svc, title="consulta")
    assert res["status"] == "success"
    svc.events.return_value.delete.assert_called_once_with(
        calendarId="primary", eventId="b", sendUpdates="all"
    )


def test_event_id_deletes_directly_without_searching():
    svc = _mock_service()
    ca = AsyncMock()
    with patch.object(GoogleCalendarClient, "get_calendar_service", return_value=svc), patch.object(
        GoogleCalendarClient, "check_availability", new=ca
    ):
        res = asyncio.run(
            _tool()(
                start_date="2026-07-20T00:00:00",
                end_date="2026-07-20T23:59:59",
                event_id="direct-1",
            )
        )
    assert res["status"] == "success"
    svc.events.return_value.delete.assert_called_once_with(
        calendarId="primary", eventId="direct-1", sendUpdates="all"
    )
    ca.assert_not_called()  # no search when event_id is given


def test_sanitized_credentials_are_reloaded_from_db():
    svc = _mock_service()
    gcs = MagicMock(return_value=svc)
    with patch(
        "src.services.adk.tools.google_calendar.cancel_event._load_full_credentials_from_db",
        return_value=FULL_CREDS,
    ) as load_mock, patch.object(
        GoogleCalendarClient, "get_calendar_service", new=gcs
    ), patch.object(
        GoogleCalendarClient,
        "check_availability",
        new=AsyncMock(return_value={"status": "success", "available": False, "events": [_event("evt-1", "R")]}),
    ):
        res = asyncio.run(
            _tool(SANITIZED_CREDS)(start_date="2026-07-20T00:00:00", end_date="2026-07-20T23:59:59")
        )
    load_mock.assert_called_once_with(AGENT_ID)
    assert res["status"] == "success"
    gcs.assert_called_once_with(FULL_CREDS)  # full creds used, not sanitized


def test_uses_selected_calendar_from_config():
    # EVO-2171: searches and deletes on settings.selectedCalendarId, not primary.
    cfg = {"settings": {"timezone": "America/Sao_Paulo", "selectedCalendarId": "mcc@agencia.bid"}}
    svc = _mock_service()
    ca = AsyncMock(return_value={"status": "success", "available": False, "events": [_event("evt-1", "R")]})
    tool = create_cancel_event_tool(
        agent_id=AGENT_ID, calendar_config=cfg, credentials_config=FULL_CREDS, db=None
    )
    with patch.object(GoogleCalendarClient, "get_calendar_service", return_value=svc), patch.object(
        GoogleCalendarClient, "check_availability", new=ca
    ):
        res = asyncio.run(tool(start_date="2026-07-20T00:00:00", end_date="2026-07-20T23:59:59"))
    assert res["status"] == "success"
    assert ca.call_args[0][3] == "mcc@agencia.bid"  # search on the selected calendar
    svc.events.return_value.delete.assert_called_once_with(
        calendarId="mcc@agencia.bid", eventId="evt-1", sendUpdates="all"
    )
