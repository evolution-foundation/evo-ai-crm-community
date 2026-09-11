"""EVO-2171: the Google Calendar tools must operate on the calendar the user picked
in the UI (settings.selectedCalendarId), not always on `primary`."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

from src.services.adk.tools.google_calendar import (
    create_check_availability_tool,
    create_calendar_event_tool,
)
from src.services.adk.tools.google_calendar.base import GoogleCalendarClient

AGENT_ID = "c9cbd608-ee35-49fe-8200-fadaaa682d87"
SELECTED = "mcc@agencia.bid"

_BH = {d: {"enabled": True, "start": "08:00", "end": "18:00"} for d in
       ["monday", "tuesday", "wednesday", "thursday", "friday"]}
_BH.update({d: {"enabled": False, "start": "08:00", "end": "18:00"} for d in ["saturday", "sunday"]})

FULL_CREDS = {"refresh_token": "rt", "client_id": "cid", "client_secret": "sec", "token": "tok"}


def _cfg(selected=None):
    settings = {"businessHours": _BH, "timezone": "America/Sao_Paulo", "minAdvanceTime": 0, "maxDuration": 0}
    if selected is not None:
        settings["selectedCalendarId"] = selected
    return {"settings": settings}


def test_check_availability_uses_selected_calendar():
    tool = create_check_availability_tool(
        agent_id=AGENT_ID, calendar_config=_cfg(SELECTED), credentials_config=FULL_CREDS, db=None
    )
    mock = AsyncMock(return_value={"status": "success", "available": True, "events": []})
    with patch.object(GoogleCalendarClient, "check_availability", new=mock):
        res = asyncio.run(
            tool(start_date="2026-07-20T00:00:00", end_date="2026-07-26T23:59:59", find_slots=True)
        )
    assert res["status"] == "success"
    # 4th positional arg to client.check_availability is the calendar id
    assert mock.call_args[0][3] == SELECTED


def test_create_event_uses_selected_calendar():
    tool = create_calendar_event_tool(
        agent_id=AGENT_ID, calendar_config=_cfg(SELECTED), credentials_config=FULL_CREDS, db=None
    )
    avail = AsyncMock(return_value={"status": "success", "available": True, "events": []})
    created = AsyncMock(
        return_value={
            "status": "success",
            "event": {"id": "e1", "summary": "R", "start": "2026-07-20T10:00:00", "end": "2026-07-20T11:00:00"},
        }
    )
    with patch.object(GoogleCalendarClient, "check_availability", new=avail), patch.object(
        GoogleCalendarClient, "create_event", new=created
    ):
        res = asyncio.run(
            tool(title="R", start_date="2026-07-20T10:00:00", end_date="2026-07-20T11:00:00")
        )
    assert res["status"] == "success"
    assert avail.call_args[0][3] == SELECTED
    assert created.call_args.kwargs["calendar_id"] == SELECTED


def test_falls_back_to_primary_without_selection():
    tool = create_check_availability_tool(
        agent_id=AGENT_ID, calendar_config=_cfg(selected=None), credentials_config=FULL_CREDS, db=None
    )
    mock = AsyncMock(return_value={"status": "success", "available": True, "events": []})
    with patch.object(GoogleCalendarClient, "check_availability", new=mock):
        asyncio.run(
            tool(start_date="2026-07-20T00:00:00", end_date="2026-07-26T23:59:59", find_slots=True)
        )
    assert mock.call_args[0][3] == "primary"


def test_empty_selection_falls_back_to_primary():
    tool = create_check_availability_tool(
        agent_id=AGENT_ID, calendar_config=_cfg(selected="   "), credentials_config=FULL_CREDS, db=None
    )
    mock = AsyncMock(return_value={"status": "success", "available": True, "events": []})
    with patch.object(GoogleCalendarClient, "check_availability", new=mock):
        asyncio.run(
            tool(start_date="2026-07-20T00:00:00", end_date="2026-07-26T23:59:59", find_slots=True)
        )
    assert mock.call_args[0][3] == "primary"  # whitespace-only selection ignored
