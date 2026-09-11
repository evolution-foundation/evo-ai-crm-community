"""Google Calendar event edit / reschedule (update) tool."""

from typing import Optional, Dict, Any
from datetime import datetime, timedelta
from google.adk.tools import FunctionTool, ToolContext
from googleapiclient.errors import HttpError
import traceback

from .base import GoogleCalendarClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def _credentials_have_secrets(creds: Optional[Dict[str, Any]]) -> bool:
    """Check whether credentials contain the fields required to refresh the token."""
    if not creds:
        return False
    return bool(
        creds.get("refresh_token")
        and creds.get("client_id")
        and creds.get("client_secret")
    )


def _load_full_credentials_from_db(agent_id: str) -> Optional[Dict[str, Any]]:
    """
    Load the full (unsanitized) Google Calendar credentials for an agent directly
    from the database (the credentials that reach the tool via agent.config.integrations
    are sanitized and lack refresh_token/client_id/client_secret).
    """
    import os

    dsn = os.environ.get("POSTGRES_CONNECTION_STRING")
    if not dsn or not agent_id:
        return None

    try:
        import psycopg2

        conn = psycopg2.connect(dsn)
        try:
            cur = conn.cursor()
            cur.execute(
                "SELECT config FROM evo_core_agent_integrations "
                "WHERE agent_id = %s AND provider = %s LIMIT 1",
                (str(agent_id), "google_calendar_credentials"),
            )
            row = cur.fetchone()
            return row[0] if row else None
        finally:
            conn.close()
    except Exception as e:
        logger.error(f"Failed to load full Google Calendar credentials from DB: {e}")
        return None


def _event_label(event: Dict[str, Any]) -> Dict[str, Any]:
    """Compact, human-friendly representation of an event."""
    start = event.get("start", {})
    end = event.get("end", {})
    return {
        "id": event.get("id"),
        "summary": event.get("summary", "(sem título)"),
        "start": start.get("dateTime") or start.get("date"),
        "end": end.get("dateTime") or end.get("date"),
    }


def create_edit_event_tool(
    agent_id: Optional[str] = None,
    calendar_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None,
) -> FunctionTool:
    """
    Create a tool for editing / rescheduling an existing Google Calendar event.

    Returns:
        FunctionTool for updating calendar events
    """
    client = GoogleCalendarClient(db=db)

    config = calendar_config.get("settings", calendar_config) if calendar_config else {}
    timezone = config.get("timezone", "America/Sao_Paulo")

    async def edit_calendar_event(
        start_date: str,
        end_date: str,
        new_start_date: Optional[str] = None,
        new_end_date: Optional[str] = None,
        new_title: Optional[str] = None,
        new_description: Optional[str] = None,
        title: Optional[str] = None,
        calendar_id: str = "primary",
        event_id: Optional[str] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Edit / reschedule an existing Google Calendar meeting.

        Use this tool when a customer wants to CHANGE a meeting they already booked
        (move it to another time, or change its title/description).

        How it works:
        - Locate the existing meeting via the time range (start_date/end_date), optionally
          filtered by title, or directly by event_id.
        - Apply only the fields provided: new_start_date/new_end_date (reschedule),
          new_title, new_description.
        - If only new_start_date is given (no new_end_date), the original duration is kept.
        - If several meetings match, the list is returned so you can ask which one to edit.

        Args:
            start_date: Start of the search range where the CURRENT meeting is (ISO format)
            end_date: End of the search range where the CURRENT meeting is (ISO format)
            new_start_date: New start date/time (ISO) to move the meeting to
            new_end_date: New end date/time (ISO); if omitted, keeps the original duration
            new_title: New title for the meeting
            new_description: New description for the meeting
            title: Optional text to match against the current title (case-insensitive)
            calendar_id: Which calendar to use
            event_id: Optional exact event id (skips the search)
            tool_context: Tool execution context
        """
        try:
            effective_agent_id = agent_id
            if not effective_agent_id:
                return {"status": "error", "message": "Agent ID is required but was not provided"}
            if not calendar_config:
                return {"status": "error", "message": "Google Calendar integration not configured for this agent"}
            if not credentials_config:
                return {"status": "error", "message": "Google Calendar credentials not configured for this agent"}

            if not any([new_start_date, new_end_date, new_title, new_description]):
                return {
                    "status": "error",
                    "message": "Informe ao menos uma alteração (novo horário, novo título ou nova descrição).",
                }

            # Load full credentials from DB when the ones passed are sanitized.
            effective_credentials = credentials_config
            if not _credentials_have_secrets(effective_credentials):
                full_creds = _load_full_credentials_from_db(effective_agent_id)
                if _credentials_have_secrets(full_creds):
                    effective_credentials = full_creds
                    logger.info("Loaded full Google Calendar credentials from database")
                else:
                    return {
                        "status": "error",
                        "message": "Google Calendar credentials are incomplete (missing OAuth secrets)",
                    }

            # EVO-2171: operate on the calendar the user picked in the UI
            # (settings.selectedCalendarId) — the same one create_event/check_availability
            # use — so edit locates and patches the event on the correct calendar. Fall
            # back to the tool arg / primary when no calendar is configured.
            _cfg = calendar_config.get("settings", calendar_config) if calendar_config else {}
            resolved_calendar_id = (_cfg.get("selectedCalendarId") or "").strip() or calendar_id or "primary"

            service = client.get_calendar_service(effective_credentials)

            # ---- locate the target event ----
            target = None
            if event_id:
                try:
                    target = service.events().get(calendarId=resolved_calendar_id, eventId=event_id).execute()
                except HttpError as e:
                    return {"status": "error", "message": f"Google Calendar API error: {str(e)}"}
            else:
                try:
                    start_dt = datetime.fromisoformat(start_date.replace("Z", "+00:00"))
                    end_dt = datetime.fromisoformat(end_date.replace("Z", "+00:00"))
                except ValueError as e:
                    return {
                        "status": "error",
                        "message": f"Invalid date format: {str(e)}. Use ISO format like '2026-07-20T09:00:00'",
                    }
                if end_dt <= start_dt:
                    end_dt = start_dt.replace(hour=23, minute=59, second=59, microsecond=0)

                logger.info(
                    f"Searching event to edit from {start_dt} to {end_dt} "
                    f"(title={title!r}) in calendar {resolved_calendar_id}"
                )
                result = await client.check_availability(effective_credentials, start_dt, end_dt, resolved_calendar_id)
                if result.get("status") == "error":
                    return result
                events = result.get("events", [])
                if title:
                    needle = title.strip().lower()
                    events = [e for e in events if needle in (e.get("summary", "").lower())]

                if not events:
                    return {"status": "error", "message": "Nenhuma reunião encontrada no período informado para editar."}
                if len(events) > 1:
                    return {
                        "status": "needs_clarification",
                        "message": (
                            f"Encontrei {len(events)} reuniões nesse período. Pergunte ao cliente qual "
                            f"editar e use o horário exato (ou o event_id) desta lista."
                        ),
                        "events": [_event_label(e) for e in events],
                    }
                target = events[0]

            target_id = target.get("id")

            # ---- build the patch body (only changed fields) ----
            body: Dict[str, Any] = {}
            if new_title:
                body["summary"] = new_title
            if new_description is not None:
                body["description"] = new_description

            # Reschedule handling
            def _parse(dt_str: str) -> datetime:
                return datetime.fromisoformat(dt_str.replace("Z", "+00:00"))

            if new_start_date:
                body["start"] = {"dateTime": _parse(new_start_date).isoformat(), "timeZone": timezone}
                if new_end_date:
                    body["end"] = {"dateTime": _parse(new_end_date).isoformat(), "timeZone": timezone}
                else:
                    # keep original duration
                    try:
                        o_start = _parse(target["start"].get("dateTime"))
                        o_end = _parse(target["end"].get("dateTime"))
                        duration = o_end - o_start
                    except Exception:
                        duration = timedelta(hours=1)
                    new_end_dt = _parse(new_start_date) + duration
                    body["end"] = {"dateTime": new_end_dt.isoformat(), "timeZone": timezone}
            elif new_end_date:
                body["end"] = {"dateTime": _parse(new_end_date).isoformat(), "timeZone": timezone}

            try:
                updated = service.events().patch(
                    calendarId=resolved_calendar_id, eventId=target_id, body=body, sendUpdates="all"
                ).execute()
            except HttpError as e:
                return {"status": "error", "message": f"Google Calendar API error: {str(e)}"}

            logger.info(f"Edited calendar event: {target_id} ({updated.get('summary')})")
            return {
                "status": "success",
                "message": f"Reunião '{updated.get('summary', '(sem título)')}' atualizada com sucesso.",
                "event": {
                    **_event_label(updated),
                    "link": updated.get("htmlLink"),
                },
            }

        except Exception as e:
            logger.error(f"Unexpected error in edit_calendar_event: {str(e)}")
            logger.error(traceback.format_exc())
            return {"status": "error", "message": f"Failed to edit calendar event: {str(e)}"}

    edit_calendar_event.__name__ = "edit_calendar_event"
    edit_calendar_event.__doc__ = f"""Edit or reschedule an existing Google Calendar meeting.

Use this when the customer wants to CHANGE a meeting already booked (move the time, or change title/description).

How it works:
1. Locate the current meeting by its time range (start_date/end_date, timezone {timezone}), optionally by title, or by event_id.
2. Provide what changes: new_start_date/new_end_date (to reschedule), new_title, new_description.
3. If only new_start_date is given, the original duration is preserved.
4. If several meetings match, you get the list to ask which one to edit.

Args:
    start_date (str): Start of the range where the CURRENT meeting is (ISO, e.g. '2026-07-20T00:00:00')
    end_date (str): End of the range where the CURRENT meeting is (ISO)
    new_start_date (str, optional): New start (ISO) to move the meeting to
    new_end_date (str, optional): New end (ISO); if omitted keeps the original duration
    new_title (str, optional): New meeting title
    new_description (str, optional): New meeting description
    title (str, optional): Text to match the current title (case-insensitive)
    calendar_id (str, optional): Calendar to use (defaults to the same as create/cancel)
    event_id (str, optional): Exact event id (skips the search)

Examples:
- Move the Jul 20 9am meeting to 2pm: start_date='2026-07-20T09:00:00', end_date='2026-07-20T10:00:00', new_start_date='2026-07-20T14:00:00'
- Rename a meeting: start_date='2026-07-20T00:00:00', end_date='2026-07-20T23:59:59', new_title='Reunião remarcada'
"""

    return edit_calendar_event
