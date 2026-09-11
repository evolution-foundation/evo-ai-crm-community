"""Google Calendar event cancellation (deletion) tool."""

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
    from the database.

    The credentials that reach this tool via agent.config.integrations are sanitized
    (they lack refresh_token/client_id/client_secret), which breaks the token refresh.
    This reads the complete credentials from evo_core_agent_integrations using a short
    lived connection, so it does not depend on the request DB session still being open.
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
    """Build a compact, human-friendly representation of an event."""
    start = event.get("start", {})
    end = event.get("end", {})
    return {
        "id": event.get("id"),
        "summary": event.get("summary", "(sem título)"),
        "start": start.get("dateTime") or start.get("date"),
        "end": end.get("dateTime") or end.get("date"),
    }


def create_cancel_event_tool(
    agent_id: Optional[str] = None,
    calendar_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None,
) -> FunctionTool:
    """
    Create a tool for cancelling (deleting) a Google Calendar event.

    Args:
        agent_id: Optional default agent ID
        calendar_config: Google Calendar configuration from agent.config.integrations
        credentials_config: Google Calendar credentials from agent.config.integrations
        db: Database session for direct database access

    Returns:
        FunctionTool for cancelling calendar events
    """
    client = GoogleCalendarClient(db=db)

    async def cancel_calendar_event(
        start_date: str,
        end_date: str,
        title: Optional[str] = None,
        calendar_id: str = "primary",
        event_id: Optional[str] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Cancel (delete) a scheduled Google Calendar event within a time range.

        Use this tool when a customer wants to cancel/unschedule a meeting they had booked.

        Behaviour:
        - Searches for events in the given time range (optionally filtered by title).
        - If exactly one event matches, it is deleted and the attendees are notified.
        - If several events match, the list is returned so you can ask which one to cancel.
        - If none match, an informative message is returned.

        Args:
            start_date: Start of the search range in ISO format (e.g. '2026-07-20T00:00:00')
            end_date: End of the search range in ISO format (e.g. '2026-07-20T23:59:59')
            title: Optional text to match against the event title (case-insensitive)
            calendar_id: Which calendar to search
            event_id: Optional exact event id to delete directly (skips the search)
            tool_context: Tool execution context

        Returns:
            Dictionary with the cancellation result
        """
        try:
            effective_agent_id = agent_id

            if not effective_agent_id:
                return {"status": "error", "message": "Agent ID is required but was not provided"}
            if not calendar_config:
                return {"status": "error", "message": "Google Calendar integration not configured for this agent"}
            if not credentials_config:
                return {"status": "error", "message": "Google Calendar credentials not configured for this agent"}

            # Credentials from agent.config.integrations are sanitized (no secrets);
            # load the full credentials from the database when the secrets are missing.
            effective_credentials = credentials_config
            if not _credentials_have_secrets(effective_credentials):
                full_creds = _load_full_credentials_from_db(effective_agent_id)
                if _credentials_have_secrets(full_creds):
                    effective_credentials = full_creds
                    logger.info("Loaded full Google Calendar credentials from database")
                else:
                    logger.error(
                        "Google Calendar credentials are missing refresh_token/client_id/"
                        "client_secret and could not be loaded from the database"
                    )
                    return {
                        "status": "error",
                        "message": "Google Calendar credentials are incomplete (missing OAuth secrets)",
                    }

            # EVO-2171: operate on the calendar the user picked in the UI
            # (settings.selectedCalendarId) — the same one create_event/check_availability
            # use — so cancel searches/deletes on the calendar the event lives on. Fall
            # back to the tool arg / primary when no calendar is configured.
            _cfg = calendar_config.get("settings", calendar_config) if calendar_config else {}
            resolved_calendar_id = (_cfg.get("selectedCalendarId") or "").strip() or calendar_id or "primary"

            service = client.get_calendar_service(effective_credentials)

            # Direct deletion by id, when provided
            if event_id:
                try:
                    service.events().delete(
                        calendarId=resolved_calendar_id, eventId=event_id, sendUpdates="all"
                    ).execute()
                    logger.info(f"Cancelled calendar event by id: {event_id}")
                    return {
                        "status": "success",
                        "message": "Reunião cancelada com sucesso.",
                        "cancelled_event": {"id": event_id},
                    }
                except HttpError as e:
                    return {"status": "error", "message": f"Google Calendar API error: {str(e)}"}

            # Parse the search range
            try:
                start_dt = datetime.fromisoformat(start_date.replace("Z", "+00:00"))
                end_dt = datetime.fromisoformat(end_date.replace("Z", "+00:00"))
            except ValueError as e:
                return {
                    "status": "error",
                    "message": f"Invalid date format: {str(e)}. Use ISO format like '2026-07-20T09:00:00'",
                }

            # If the caller passed a single instant / inverted range, expand to the whole day
            if end_dt <= start_dt:
                end_dt = start_dt.replace(hour=23, minute=59, second=59, microsecond=0)

            logger.info(
                f"Searching events to cancel from {start_dt} to {end_dt} "
                f"(title={title!r}) in calendar {resolved_calendar_id}"
            )

            # List events in the window (single API call)
            result = await client.check_availability(
                effective_credentials, start_dt, end_dt, resolved_calendar_id
            )
            if result.get("status") == "error":
                return result

            events = result.get("events", [])

            # Filter by title if provided
            if title:
                needle = title.strip().lower()
                events = [
                    e for e in events
                    if needle in (e.get("summary", "").lower())
                ]

            if not events:
                return {
                    "status": "error",
                    "message": "Nenhuma reunião encontrada no período informado para cancelar.",
                }

            if len(events) > 1:
                return {
                    "status": "needs_clarification",
                    "message": (
                        f"Encontrei {len(events)} reuniões nesse período. "
                        f"Pergunte ao cliente qual delas deseja cancelar e informe o horário exato "
                        f"(ou o event_id) desta lista."
                    ),
                    "events": [_event_label(e) for e in events],
                }

            # Exactly one match -> delete it
            target = events[0]
            target_id = target.get("id")
            try:
                service.events().delete(
                    calendarId=resolved_calendar_id, eventId=target_id, sendUpdates="all"
                ).execute()
            except HttpError as e:
                return {"status": "error", "message": f"Google Calendar API error: {str(e)}"}

            logger.info(f"Cancelled calendar event: {target_id} ({target.get('summary')})")
            return {
                "status": "success",
                "message": (
                    f"Reunião '{target.get('summary', '(sem título)')}' cancelada com sucesso."
                ),
                "cancelled_event": _event_label(target),
            }

        except Exception as e:
            logger.error(f"Unexpected error in cancel_calendar_event: {str(e)}")
            logger.error(traceback.format_exc())
            return {"status": "error", "message": f"Failed to cancel calendar event: {str(e)}"}

    cancel_calendar_event.__name__ = "cancel_calendar_event"

    # Timezone hint for the docstring
    config = calendar_config.get("settings", calendar_config) if calendar_config else {}
    timezone = config.get("timezone", "America/Sao_Paulo")

    cancel_calendar_event.__doc__ = f"""Cancel (delete) a scheduled Google Calendar meeting.

Use this tool when the customer wants to cancel / unschedule a meeting that was previously booked.

How it works:
1. Give the time range where the meeting is (start_date/end_date, in timezone {timezone}).
2. Optionally pass a title to disambiguate.
3. If exactly one meeting is found it is cancelled and attendees are notified.
4. If several are found, you receive the list to ask the customer which one to cancel.

Args:
    start_date (str): Start of the search range in ISO format (e.g. '2026-07-20T00:00:00')
    end_date (str): End of the search range in ISO format (e.g. '2026-07-20T23:59:59')
    title (str, optional): Text to match against the meeting title (case-insensitive)
    calendar_id (str, optional): Calendar to search (defaults to the agent's selected calendar)
    event_id (str, optional): Exact event id to delete directly (skips the search)

Examples:
- Cancel the meeting on Jul 20 morning: start_date='2026-07-20T00:00:00', end_date='2026-07-20T12:00:00'
- Cancel a specific 9am meeting: start_date='2026-07-20T09:00:00', end_date='2026-07-20T10:00:00'
"""

    return cancel_calendar_event
