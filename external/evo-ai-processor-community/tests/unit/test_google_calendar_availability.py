"""Google Calendar availability/scheduling regression tests.

Covers the three chained bugs fixed in the umbrella PR:

1. businessHours.enabled was tested at the ROOT level (it only exists per-day),
   so every day was skipped -> "Found 0 available time slots".
2. Credentials arrive SANITIZED (no refresh_token/client_id/client_secret) at the
   tools, breaking the Google token refresh -> RefreshError. The tool must reload
   the full credentials from the database.
3. Availability search made ONE Google API call PER candidate slot (~60 calls),
   blowing past the bot_runtime 30s timeout. It must prefetch the window once and
   test slots in memory.

The tools are closures, so we exercise them through their public factory
functions and patch GoogleCalendarClient / the module-level DB loader.
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

from src.services.adk.tools.google_calendar import (
    create_check_availability_tool,
    create_calendar_event_tool,
)
from src.services.adk.tools.google_calendar.base import GoogleCalendarClient
from src.services.adk.tools.google_calendar.check_availability import (
    _credentials_have_secrets,
)

AGENT_ID = "c9cbd608-ee35-49fe-8200-fadaaa682d87"

# businessHours as saved by the CRM: `enabled` is PER DAY, there is no root `enabled`.
BUSINESS_HOURS = {
    "monday": {"enabled": True, "start": "08:00", "end": "18:00"},
    "tuesday": {"enabled": True, "start": "08:00", "end": "18:00"},
    "wednesday": {"enabled": True, "start": "08:00", "end": "18:00"},
    "thursday": {"enabled": True, "start": "08:00", "end": "18:00"},
    "friday": {"enabled": True, "start": "08:00", "end": "18:00"},
    "saturday": {"enabled": False, "start": "08:00", "end": "18:00"},
    "sunday": {"enabled": False, "start": "08:00", "end": "18:00"},
}
CALENDAR_CONFIG = {
    "settings": {
        "businessHours": BUSINESS_HOURS,
        "timezone": "America/Sao_Paulo",
        "minAdvanceTime": 0,
        "maxDuration": 0,
        "connected": True,
    }
}

FULL_CREDS = {
    "refresh_token": "1//full-refresh-token",
    "client_id": "client-id.apps.googleusercontent.com",
    "client_secret": "the-secret",
    "token": "ya29.access-token",
    "token_uri": "https://oauth2.googleapis.com/token",
}
# Exactly the keys the report observed reaching the tool (secrets stripped).
SANITIZED_CREDS = {
    "connected": True,
    "email": "mcc@agencia.bid",
    "provider": "google_calendar_credentials",
    "scopes": ["https://www.googleapis.com/auth/calendar.events"],
    "token_uri": "https://oauth2.googleapis.com/token",
}

# A full week: 2026-07-20 (Mon) .. 2026-07-26 (Sun).
WEEK_START = "2026-07-20T00:00:00"
WEEK_END = "2026-07-26T23:59:59"


def _free_calendar():
    """AsyncMock for GoogleCalendarClient.check_availability: empty/free calendar."""
    return AsyncMock(return_value={"status": "success", "available": True, "events": []})


# --------------------------------------------------------------------------- #
# Bug #2 helper
# --------------------------------------------------------------------------- #
def test_credentials_have_secrets_detects_sanitized_vs_full():
    assert _credentials_have_secrets(FULL_CREDS) is True
    assert _credentials_have_secrets(SANITIZED_CREDS) is False
    assert _credentials_have_secrets(None) is False
    assert _credentials_have_secrets({"refresh_token": "x"}) is False  # partial


# --------------------------------------------------------------------------- #
# Bug #1 (per-day business hours) + Bug #3 (single prefetch call)
# --------------------------------------------------------------------------- #
def test_find_slots_uses_per_day_business_hours_and_prefetches_once():
    tool = create_check_availability_tool(
        agent_id=AGENT_ID,
        calendar_config=CALENDAR_CONFIG,
        credentials_config=FULL_CREDS,
        db=None,
    )
    mock = _free_calendar()
    with patch.object(GoogleCalendarClient, "check_availability", new=mock):
        result = asyncio.run(
            tool(start_date=WEEK_START, end_date=WEEK_END, find_slots=True, slot_duration=60)
        )

    assert result["status"] == "success"
    # Bug #1: the root-`enabled` gate used to skip every day -> 0 slots.
    assert len(result["available_slots"]) > 0
    # Bug #3: the whole window is prefetched with a SINGLE API call, not one per slot.
    assert mock.call_count == 1
    # Weekend days (enabled: false) are excluded.
    days = {slot["start"][:10] for slot in result["available_slots"]}
    assert "2026-07-25" not in days  # Saturday
    assert "2026-07-26" not in days  # Sunday
    assert "2026-07-20" in days  # Monday has slots


def test_find_slots_marks_overlapping_slots_busy_in_memory():
    # One busy event Monday 08:00-09:00 (UTC-3 -> 11:00-12:00 UTC). Slots overlapping
    # it must be excluded; adjacent free slots must remain.
    busy_event = {
        "start": {"dateTime": "2026-07-20T08:00:00-03:00"},
        "end": {"dateTime": "2026-07-20T09:00:00-03:00"},
    }
    mock = AsyncMock(
        return_value={"status": "success", "available": False, "events": [busy_event]}
    )
    tool = create_check_availability_tool(
        agent_id=AGENT_ID,
        calendar_config=CALENDAR_CONFIG,
        credentials_config=FULL_CREDS,
        db=None,
    )
    with patch.object(GoogleCalendarClient, "check_availability", new=mock):
        result = asyncio.run(
            tool(start_date=WEEK_START, end_date=WEEK_END, find_slots=True, slot_duration=60)
        )

    assert result["status"] == "success"
    assert mock.call_count == 1
    monday_starts = {
        s["start"][11:16] for s in result["available_slots"] if s["start"][:10] == "2026-07-20"
    }
    # 08:00 and 08:30 slots overlap the busy hour -> excluded.
    assert "08:00" not in monday_starts
    assert "08:30" not in monday_starts
    # 09:00 onward is free.
    assert "09:00" in monday_starts


# --------------------------------------------------------------------------- #
# Bug #2 (sanitized credentials reloaded from DB)
# --------------------------------------------------------------------------- #
def test_sanitized_credentials_are_reloaded_from_db_for_availability():
    tool = create_check_availability_tool(
        agent_id=AGENT_ID,
        calendar_config=CALENDAR_CONFIG,
        credentials_config=SANITIZED_CREDS,
        db=None,
    )
    mock = _free_calendar()
    with patch(
        "src.services.adk.tools.google_calendar.check_availability._load_full_credentials_from_db",
        return_value=FULL_CREDS,
    ) as load_mock, patch.object(GoogleCalendarClient, "check_availability", new=mock):
        result = asyncio.run(
            tool(start_date=WEEK_START, end_date=WEEK_END, find_slots=True, slot_duration=60)
        )

    load_mock.assert_called_once_with(AGENT_ID)
    assert result["status"] == "success"
    # The prefetch must have used the FULL creds loaded from the DB, not the sanitized ones.
    used_creds = mock.call_args[0][0]
    assert used_creds == FULL_CREDS


def test_incomplete_credentials_returns_explicit_error():
    tool = create_check_availability_tool(
        agent_id=AGENT_ID,
        calendar_config=CALENDAR_CONFIG,
        credentials_config=SANITIZED_CREDS,
        db=None,
    )
    with patch(
        "src.services.adk.tools.google_calendar.check_availability._load_full_credentials_from_db",
        return_value=None,
    ):
        result = asyncio.run(
            tool(start_date=WEEK_START, end_date=WEEK_END, find_slots=True, slot_duration=60)
        )

    assert result["status"] == "error"
    assert "incomplete" in result["message"].lower()


def test_sanitized_credentials_are_reloaded_from_db_for_create_event():
    tool = create_calendar_event_tool(
        agent_id=AGENT_ID,
        calendar_config=CALENDAR_CONFIG,
        credentials_config=SANITIZED_CREDS,
        db=None,
    )
    avail = _free_calendar()
    created = AsyncMock(
        return_value={
            "status": "success",
            "event": {
                "id": "evt-123",
                "summary": "Reunião",
                "start": "2026-07-20T10:00:00",
                "end": "2026-07-20T11:00:00",
                "link": "https://calendar.google.com/evt-123",
            },
        }
    )
    with patch(
        "src.services.adk.tools.google_calendar.create_event._load_full_credentials_from_db",
        return_value=FULL_CREDS,
    ) as load_mock, patch.object(
        GoogleCalendarClient, "check_availability", new=avail
    ), patch.object(GoogleCalendarClient, "create_event", new=created):
        result = asyncio.run(
            tool(
                title="Reunião sobre Franquia",
                start_date="2026-07-20T10:00:00",
                end_date="2026-07-20T11:00:00",
            )
        )

    load_mock.assert_called_once_with(AGENT_ID)
    assert result["status"] == "success"
    # Both the availability check and the event creation use the full DB creds.
    assert avail.call_args[0][0] == FULL_CREDS
    assert created.call_args.kwargs["credentials_config"] == FULL_CREDS
