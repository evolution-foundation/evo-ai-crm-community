"""Google Calendar event creation tool."""

from typing import Optional, Dict, Any, List
from datetime import datetime
from google.adk.tools import FunctionTool, ToolContext
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


def create_calendar_event_tool(
    agent_id: Optional[str] = None,
    calendar_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None
) -> FunctionTool:
    """
    Create a tool for creating Google Calendar events.

    Args:
        agent_id: Optional default agent ID
        calendar_config: Google Calendar configuration from agent.config.integrations
        credentials_config: Google Calendar credentials from agent.config.integrations
        db: Database session for direct database access

    Returns:
        FunctionTool for creating calendar events
    """
    client = GoogleCalendarClient(db=db)

    async def create_calendar_event(
        title: str,
        start_date: str,
        end_date: str,
        description: str = "",
        attendees: Optional[List[str]] = None,
        calendar_id: str = "primary",
        check_availability: bool = True,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Create a new event in Google Calendar.

        This tool creates calendar events while respecting the agent's configuration:
        - Business hours restrictions
        - Minimum advance time
        - Maximum event duration
        - Automatic Google Meet link creation (if enabled)
        - Email invitations to attendees (if enabled)

        Use this tool when:
        - A customer confirms a meeting time
        - You need to schedule an appointment
        - You want to create a calendar event with attendees

        The tool will automatically validate:
        - Event is within business hours
        - Sufficient advance notice
        - Duration doesn't exceed limits
        - No conflicting events (if check_availability=True)

        Args:
            title: Event title
            start_date: Start date/time in ISO format
            end_date: End date/time in ISO format
            description: Optional event description
            attendees: Optional list of attendee emails
            calendar_id: Which calendar to use
            check_availability: Whether to verify no conflicts exist
            tool_context: Tool execution context

        Returns:
            Dictionary with created event details or error message
        """
        try:
            logger.info(f"Creating calendar event: {title} from {start_date} to {end_date}")

            # Use agent_id from closure (passed to create_calendar_event_tool)
            effective_agent_id = agent_id

            # Validate required parameters
            if not effective_agent_id:
                return {
                    "status": "error",
                    "message": "Agent ID is required but was not provided"
                }

            # Validate configs provided
            if not calendar_config:
                return {
                    "status": "error",
                    "message": "Google Calendar integration not configured for this agent"
                }

            if not credentials_config:
                return {
                    "status": "error",
                    "message": "Google Calendar credentials not configured for this agent"
                }

            # Credentials from agent.config.integrations are sanitized (no secrets),
            # which makes the Google token refresh fail. Load the full credentials from
            # the database when the secret fields are missing.
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
                        "message": "Google Calendar credentials are incomplete (missing OAuth secrets)"
                    }

            if not title or not title.strip():
                return {
                    "status": "error",
                    "message": "Event title is required"
                }

            # Parse dates
            try:
                start_dt = datetime.fromisoformat(start_date.replace('Z', '+00:00'))
                end_dt = datetime.fromisoformat(end_date.replace('Z', '+00:00'))
            except ValueError as e:
                return {
                    "status": "error",
                    "message": f"Invalid date format: {str(e)}. Use ISO format like '2024-01-15T14:00:00'"
                }

            # Validate date range
            if end_dt <= start_dt:
                return {
                    "status": "error",
                    "message": "End date must be after start date"
                }

            # Use configs from closure (passed from agent.config.integrations)
            # Support both flat and nested structures
            if "settings" in calendar_config:
                config = calendar_config["settings"]
            else:
                # Config values are directly in calendar_config
                config = calendar_config

            # EVO-2171: honour the calendar the user picked in the UI
            # (settings.selectedCalendarId). The config selection is authoritative;
            # fall back to the tool arg / primary.
            resolved_calendar_id = (config.get("selectedCalendarId") or "").strip() or calendar_id or "primary"

            # Helper to extract value from config (handles both dict and direct values)
            def get_config_value(key: str, default: Any) -> Any:
                value = config.get(key, default)
                # If value is a dict with 'value' key, extract it and convert units
                if isinstance(value, dict) and "value" in value:
                    extracted_value = value["value"]
                    unit = value.get("unit")

                    # Convert time units to appropriate format
                    if key in ["minAdvanceTime", "maxDistance"] and unit == "hours":
                        return extracted_value  # Already in hours
                    elif key in ["minAdvanceTime", "maxDistance"] and unit == "weeks":
                        return extracted_value * 24 * 7  # Convert weeks to hours
                    elif key == "maxDuration" and unit == "hours":
                        return extracted_value * 60  # Convert hours to minutes
                    elif key == "maxDuration" and unit == "minutes":
                        return extracted_value  # Already in minutes

                    return extracted_value
                return value

            # Check availability if requested
            if check_availability:
                logger.info(f"Checking availability for {start_date} to {end_date}")
                availability_result = await client.check_availability(
                    effective_credentials,
                    start_dt,
                    end_dt,
                    resolved_calendar_id
                )

                if availability_result["status"] == "error":
                    logger.error(f"Availability check failed: {availability_result.get('message')}")
                    return availability_result

                if not availability_result["available"]:
                    logger.warning("Time slot has conflicting events")
                    conflicting_events = availability_result.get("events", [])
                    return {
                        "status": "error",
                        "message": "Time slot has conflicting events",
                        "conflicting_events": [
                            {
                                "summary": event.get("summary", "Untitled"),
                                "start": event.get("start", {}).get("dateTime"),
                                "end": event.get("end", {}).get("dateTime")
                            }
                            for event in conflicting_events
                        ]
                    }

            # Create the event
            logger.info(f"Creating event in Google Calendar")
            result = await client.create_event(
                credentials_config=effective_credentials,
                config=config,
                summary=title,
                start_time=start_dt,
                end_time=end_dt,
                description=description,
                attendees=attendees,
                calendar_id=resolved_calendar_id
            )

            if result["status"] == "error":
                logger.error(f"Event creation failed: {result.get('message')}")
                return result

            # Build success response
            event_details = result.get("event", {})
            response = {
                "status": "success",
                "message": f"Event '{title}' created successfully",
                "event": {
                    "id": event_details.get("id"),
                    "title": event_details.get("summary"),
                    "start": event_details.get("start"),
                    "end": event_details.get("end"),
                    "link": event_details.get("link"),
                    "duration_minutes": int((end_dt - start_dt).total_seconds() / 60)
                }
            }

            # Add Google Meet link if present
            if event_details.get("meet_link"):
                response["event"]["meet_link"] = event_details["meet_link"]
                response["message"] += " with Google Meet link"

            # Add attendees info
            if attendees and len(attendees) > 0:
                response["event"]["attendees"] = attendees
                response["event"]["attendee_count"] = len(attendees)

                if get_config_value("sendInvitations", False):
                    response["message"] += f" and invitations sent to {len(attendees)} attendee(s)"

            logger.info(f"Event created successfully: {event_details.get('id')}")
            return response

        except Exception as e:
            logger.error(f"Unexpected error in create_calendar_event: {str(e)}")
            logger.error(traceback.format_exc())
            return {
                "status": "error",
                "message": f"Failed to create calendar event: {str(e)}"
            }

    # Set function metadata
    create_calendar_event.__name__ = "create_calendar_event"

    # Build dynamic docstring with config constraints
    config = calendar_config.get("settings", calendar_config) if calendar_config else {}

    def get_config_value(key: str, default: Any) -> Any:
        value = config.get(key, default)
        if isinstance(value, dict) and "value" in value:
            extracted_value = value["value"]
            unit = value.get("unit")

            # Convert time units to appropriate format
            if key in ["minAdvanceTime", "maxDistance"] and unit == "hours":
                return extracted_value  # Already in hours
            elif key in ["minAdvanceTime", "maxDistance"] and unit == "weeks":
                return extracted_value * 24 * 7  # Convert weeks to hours
            elif key == "maxDuration" and unit == "hours":
                return extracted_value * 60  # Convert hours to minutes
            elif key == "maxDuration" and unit == "minutes":
                return extracted_value  # Already in minutes

            return extracted_value
        return value

    # Extract configuration
    business_hours = get_config_value("businessHours", {})
    min_advance_time = get_config_value("minAdvanceTime", 0)
    max_duration = get_config_value("maxDuration", 0)
    enable_google_meet = get_config_value("enableGoogleMeet", False)
    send_invitations = get_config_value("sendInvitations", False)
    timezone = get_config_value("timezone", "America/Sao_Paulo")

    # Build business hours description
    bh_description = ""
    if business_hours and business_hours.get("enabled"):
        bh_description = "\n\nBUSINESS HOURS CONFIGURED:\n"
        day_names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for day_name in day_names:
            day_config = business_hours.get(day_name, {})
            if day_config and day_config.get("enabled"):
                start = day_config.get("start", "09:00")
                end = day_config.get("end", "18:00")
                bh_description += f"- {day_name.capitalize()}: {start} to {end}\n"

    # Build constraints description
    constraints = []
    if min_advance_time > 0:
        constraints.append(f"- Meetings must be scheduled at least {min_advance_time} hours in advance")
    if max_duration > 0:
        constraints.append(f"- Maximum meeting duration: {max_duration} minutes")

    constraints_description = ""
    if constraints:
        constraints_description = "\n\nSCHEDULING CONSTRAINTS:\n" + "\n".join(constraints)

    # Build features description
    features = []
    if enable_google_meet:
        features.append("- Automatically creates Google Meet links for all events")
    if send_invitations:
        features.append("- Automatically sends email invitations to attendees")

    features_description = ""
    if features:
        features_description = "\n\nFEATURES ENABLED:\n" + "\n".join(features)

    create_calendar_event.__doc__ = f"""Create a new event in Google Calendar with automatic validation.
{bh_description}{constraints_description}{features_description}

IMPORTANT: Always respect the business hours and scheduling constraints above when creating events for customers.

Args:
    title (str): Event title/summary (e.g., 'Meeting with John')
    start_date (str): Event start date and time in ISO format (e.g., '2024-01-15T14:00:00') in timezone {timezone}
    end_date (str): Event end date and time in ISO format (e.g., '2024-01-15T15:00:00') in timezone {timezone}
    description (str, optional): Event description (default: "")
    attendees (list, optional): List of attendee email addresses (default: None)
    calendar_id (str, optional): Calendar ID where event should be created (default: 'primary')
    check_availability (bool, optional): Whether to check availability before creating event (default: True)

Examples:
- Schedule a meeting: title='Customer Meeting', start_date='2024-01-16T14:00:00', end_date='2024-01-16T15:00:00'
- Create event with attendees: title='Team Sync', start_date='2024-01-16T10:00:00', end_date='2024-01-16T11:00:00', attendees=['john@example.com', 'jane@example.com']
- Schedule without availability check: title='Personal Task', start_date='2024-01-16T09:00:00', end_date='2024-01-16T09:30:00', check_availability=False
"""

    return create_calendar_event
