"""EVO-2170: edit_calendar_event tool (edit / reschedule an existing meeting)."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from src.services.adk.tools.google_calendar import create_edit_event_tool
from src.services.adk.tools.google_calendar.base import GoogleCalendarClient

AGENT_ID = "c9cbd608-ee35-49fe-8200-fadaaa682d87"
CALENDAR_CONFIG = {"settings": {"timezone": "America/Sao_Paulo", "connected": True}}

FULL_CREDS = {"refresh_token": "rt", "client_id": "cid", "client_secret": "sec", "token": "tok"}
SANITIZED_CREDS = {"connected": True, "email": "x@y.com", "provider": "google_calendar_credentials"}


def _event(eid, summary, start, end):
    return {
        "id": eid,
        "summary": summary,
        "start": {"dateTime": start},
        "end": {"dateTime": end},
    }


TARGET = _event("evt-1", "Reunião", "2026-07-20T14:00:00-03:00", "2026-07-20T15:00:00-03:00")


def _mock_service(target=None):
    svc = MagicMock()
    svc.events.return_value.patch.return_value.execute.return_value = {
        "id": "evt-1",
        "summary": "Reunião",
        "start": {"dateTime": "2026-07-20T16:30:00-03:00"},
        "end": {"dateTime": "2026-07-20T17:30:00-03:00"},
        "htmlLink": "https://calendar.google.com/evt-1",
    }
    if target is not None:
        svc.events.return_value.get.return_value.execute.return_value = target
    return svc


def _tool(creds=FULL_CREDS):
    return create_edit_event_tool(
        agent_id=AGENT_ID, calendar_config=CALENDAR_CONFIG, credentials_config=creds, db=None
    )


def _run_search(tool, events, svc, **kwargs):
    with patch.object(GoogleCalendarClient, "get_calendar_service", return_value=svc), patch.object(
        GoogleCalendarClient,
        "check_availability",
        new=AsyncMock(return_value={"status": "success", "available": False, "events": events}),
    ):
        return asyncio.run(
            tool(start_date="2026-07-20T00:00:00", end_date="2026-07-20T23:59:59", **kwargs)
        )


def test_reschedule_new_start_only_preserves_duration():
    svc = _mock_service()
    res = _run_search(_tool(), [TARGET], svc, new_start_date="2026-07-20T16:30:00-03:00")
    assert res["status"] == "success"
    body = svc.events.return_value.patch.call_args.kwargs["body"]
    assert "16:30:00" in body["start"]["dateTime"]
    assert "17:30:00" in body["end"]["dateTime"]  # original 1h duration preserved
    assert "summary" not in body  # title untouched


def test_change_title_only_patches_summary_no_times():
    svc = _mock_service()
    res = _run_search(_tool(), [TARGET], svc, new_title="Reunião remarcada")
    assert res["status"] == "success"
    body = svc.events.return_value.patch.call_args.kwargs["body"]
    assert body["summary"] == "Reunião remarcada"
    assert "start" not in body and "end" not in body


def test_explicit_new_start_and_end_are_used():
    svc = _mock_service()
    res = _run_search(
        _tool(),
        [TARGET],
        svc,
        new_start_date="2026-07-20T09:00:00-03:00",
        new_end_date="2026-07-20T10:30:00-03:00",
    )
    assert res["status"] == "success"
    body = svc.events.return_value.patch.call_args.kwargs["body"]
    assert "09:00:00" in body["start"]["dateTime"]
    assert "10:30:00" in body["end"]["dateTime"]


def test_no_change_field_returns_error():
    svc = _mock_service()
    res = _run_search(_tool(), [TARGET], svc)  # no new_* provided
    assert res["status"] == "error"
    assert "alteração" in res["message"].lower()
    svc.events.return_value.patch.assert_not_called()


def test_multiple_matches_ask_for_disambiguation():
    svc = _mock_service()
    other = _event("evt-2", "Outra", "2026-07-20T11:00:00-03:00", "2026-07-20T12:00:00-03:00")
    res = _run_search(_tool(), [TARGET, other], svc, new_title="X")
    assert res["status"] == "needs_clarification"
    assert len(res["events"]) == 2
    svc.events.return_value.patch.assert_not_called()


def test_no_match_returns_informative_message():
    svc = _mock_service()
    res = _run_search(_tool(), [], svc, new_title="X")
    assert res["status"] == "error"
    assert "nenhuma" in res["message"].lower()
    svc.events.return_value.patch.assert_not_called()


def test_event_id_locates_via_get_then_patches():
    svc = _mock_service(target=TARGET)
    ca = AsyncMock()
    with patch.object(GoogleCalendarClient, "get_calendar_service", return_value=svc), patch.object(
        GoogleCalendarClient, "check_availability", new=ca
    ):
        res = asyncio.run(
            _tool()(
                start_date="2026-07-20T00:00:00",
                end_date="2026-07-20T23:59:59",
                event_id="evt-1",
                new_start_date="2026-07-20T16:30:00-03:00",
            )
        )
    assert res["status"] == "success"
    svc.events.return_value.get.assert_called_once_with(calendarId="primary", eventId="evt-1")
    ca.assert_not_called()  # no search when event_id is given
    svc.events.return_value.patch.assert_called_once()


def test_sanitized_credentials_are_reloaded_from_db():
    svc = _mock_service()
    gcs = MagicMock(return_value=svc)
    with patch(
        "src.services.adk.tools.google_calendar.edit_event._load_full_credentials_from_db",
        return_value=FULL_CREDS,
    ) as load_mock, patch.object(
        GoogleCalendarClient, "get_calendar_service", new=gcs
    ), patch.object(
        GoogleCalendarClient,
        "check_availability",
        new=AsyncMock(return_value={"status": "success", "available": False, "events": [TARGET]}),
    ):
        res = asyncio.run(
            _tool(SANITIZED_CREDS)(
                start_date="2026-07-20T00:00:00",
                end_date="2026-07-20T23:59:59",
                new_title="X",
            )
        )
    load_mock.assert_called_once_with(AGENT_ID)
    assert res["status"] == "success"
    gcs.assert_called_once_with(FULL_CREDS)


def test_uses_selected_calendar_from_config():
    # EVO-2171: locates and patches on settings.selectedCalendarId, not primary.
    cfg = {"settings": {"timezone": "America/Sao_Paulo", "selectedCalendarId": "mcc@agencia.bid"}}
    svc = _mock_service()
    ca = AsyncMock(return_value={"status": "success", "available": False, "events": [TARGET]})
    tool = create_edit_event_tool(
        agent_id=AGENT_ID, calendar_config=cfg, credentials_config=FULL_CREDS, db=None
    )
    with patch.object(GoogleCalendarClient, "get_calendar_service", return_value=svc), patch.object(
        GoogleCalendarClient, "check_availability", new=ca
    ):
        res = asyncio.run(
            tool(start_date="2026-07-20T00:00:00", end_date="2026-07-20T23:59:59", new_title="X")
        )
    assert res["status"] == "success"
    assert ca.call_args[0][3] == "mcc@agencia.bid"  # search on the selected calendar
    assert svc.events.return_value.patch.call_args.kwargs["calendarId"] == "mcc@agencia.bid"
