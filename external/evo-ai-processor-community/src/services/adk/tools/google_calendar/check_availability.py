"""Google Calendar availability checking tool."""

from typing import Optional, Dict, Any
from datetime import datetime, timedelta
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


def create_check_availability_tool(
    agent_id: Optional[str] = None,
    calendar_config: Optional[Dict[str, Any]] = None,
    credentials_config: Optional[Dict[str, Any]] = None,
    db=None
) -> FunctionTool:
    """
    Create a tool for checking Google Calendar availability.

    Args:
        agent_id: Optional default agent ID
        calendar_config: Google Calendar configuration from agent.config.integrations
        credentials_config: Google Calendar credentials from agent.config.integrations
        db: Database session for direct database access

    Returns:
        FunctionTool for checking calendar availability
    """
    client = GoogleCalendarClient(db=db)

    async def check_calendar_availability(
        start_date: str,
        end_date: str,
        calendar_id: str = "primary",
        find_slots: bool = False,
        slot_duration: int = 60,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """
        Check Google Calendar availability for a given time range.

        This tool checks if there are any events scheduled in the specified time range,
        respecting the agent's business hours configuration. It can also find available
        time slots within a date range.

        Use this tool when:
        - A customer asks about available times for a meeting
        - You need to check if a specific time slot is free
        - You want to suggest available time slots to a customer

        Args:
            start_date: Start date/time in ISO format
            end_date: End date/time in ISO format
            calendar_id: Which calendar to check
            find_slots: Whether to return available time slots
            slot_duration: Duration of each slot in minutes
            tool_context: Tool execution context

        Returns:
            Dictionary with availability status and details
        """
        try:
            logger.info(f"Checking calendar availability from {start_date} to {end_date}, find_slots={find_slots}")
            logger.debug(f"Calendar config received: {calendar_config}")
            logger.debug(f"Credentials available: {bool(credentials_config)}")

            # Use agent_id from closure (passed to create_check_availability_tool)
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

            # The credentials from agent.config.integrations are sanitized (no secrets),
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

            # Parse dates
            try:
                start_dt = datetime.fromisoformat(start_date.replace('Z', '+00:00'))
                end_dt = datetime.fromisoformat(end_date.replace('Z', '+00:00'))
            except ValueError as e:
                return {
                    "status": "error",
                    "message": f"Invalid date format: {str(e)}. Use ISO format like '2024-01-15T09:00:00'"
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
            # (settings.selectedCalendarId). The LLM cannot know the calendar id, so
            # the config selection is authoritative; fall back to the tool arg / primary.
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

            # If find_slots is True, find available slots
            if find_slots:
                return await _find_available_slots(
                    client,
                    effective_credentials,
                    start_dt,
                    end_dt,
                    slot_duration,
                    resolved_calendar_id,
                    config
                )

            # Otherwise, just check if the specific range is available
            result = await client.check_availability(
                effective_credentials,
                start_dt,
                end_dt,
                resolved_calendar_id
            )

            if result["status"] == "error":
                return result

            # Check business hours
            business_hours = get_config_value("businessHours", {})
            within_business_hours = client.is_within_business_hours(start_dt, business_hours)

            # Check minimum advance time
            timezone = get_config_value("timezone", "America/Sao_Paulo")
            min_advance_time = get_config_value("minAdvanceTime", 0)
            advance_time_ok = client.validate_advance_time(start_dt, min_advance_time, timezone)

            # Check maximum duration
            duration_minutes = int((end_dt - start_dt).total_seconds() / 60)
            max_duration = get_config_value("maxDuration", 0)
            duration_ok = client.validate_max_duration(duration_minutes, max_duration)

            # Build response
            is_available = (
                result["available"]
                and within_business_hours
                and advance_time_ok
                and duration_ok
            )

            response = {
                "status": "success",
                "available": is_available,
                "start_time": start_date,
                "end_time": end_date,
                "duration_minutes": duration_minutes,
                "checks": {
                    "no_conflicts": result["available"],
                    "within_business_hours": within_business_hours,
                    "sufficient_advance_time": advance_time_ok,
                    "duration_within_limit": duration_ok
                }
            }

            # Add human-readable message
            if is_available:
                response["message"] = f"Time slot is available from {start_date} to {end_date}"
            else:
                reasons = []
                if not result["available"]:
                    reasons.append("there are existing events in this time slot")
                if not within_business_hours:
                    reasons.append("time is outside business hours")
                if not advance_time_ok:
                    reasons.append(f"must be scheduled at least {min_advance_time} hours in advance")
                if not duration_ok:
                    reasons.append(f"duration exceeds maximum of {max_duration} minutes")

                response["message"] = f"Time slot is not available: {', '.join(reasons)}"

            # Add conflicting events if any
            if not result["available"]:
                response["conflicting_events"] = [
                    {
                        "summary": event.get("summary", "Untitled"),
                        "start": event.get("start", {}).get("dateTime"),
                        "end": event.get("end", {}).get("dateTime")
                    }
                    for event in result.get("events", [])
                ]

            logger.info(f"Availability check completed: available={is_available}")
            return response

        except Exception as e:
            logger.error(f"Unexpected error in check_calendar_availability: {str(e)}")
            logger.error(traceback.format_exc())
            return {
                "status": "error",
                "message": f"Failed to check calendar availability: {str(e)}"
            }

    async def _find_available_slots(
        client: GoogleCalendarClient,
        credentials_config: Dict[str, Any],
        start_dt: datetime,
        end_dt: datetime,
        slot_duration: int,
        calendar_id: str,
        config: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Find available time slots within a date range.

        Args:
            client: GoogleCalendarClient instance
            credentials_config: Google Calendar credentials configuration
            start_dt: Start of search range
            end_dt: End of search range
            slot_duration: Duration of each slot in minutes
            calendar_id: Calendar to check
            config: Integration configuration

        Returns:
            Dictionary with available time slots
        """
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

        available_slots = []
        business_hours = get_config_value("businessHours", {})
        timezone = get_config_value("timezone", "America/Sao_Paulo")
        min_advance_time = get_config_value("minAdvanceTime", 0)
        max_duration = get_config_value("maxDuration", 0)

        logger.info(f"Finding available slots: business_hours_enabled={business_hours.get('enabled')}, timezone={timezone}, min_advance={min_advance_time}h, max_duration={max_duration}min")

        # Validate slot duration
        if max_duration > 0 and slot_duration > max_duration:
            return {
                "status": "error",
                "message": f"Slot duration ({slot_duration} min) exceeds maximum duration ({max_duration} min)"
            }

        # Iterate through days
        current_day = start_dt.replace(hour=0, minute=0, second=0, microsecond=0)
        end_day = end_dt.replace(hour=23, minute=59, second=59, microsecond=999999)

        logger.info(f"Searching slots from {current_day} to {end_day}")

        # Fetch every event for the whole search window in a SINGLE API call and then
        # test each candidate slot against them in memory. The previous implementation
        # made one Google API call per candidate slot (dozens of sequential HTTP calls),
        # which took ~40s+ and blew past the bot runtime's 30s timeout, so the generated
        # answer was never delivered to the customer.
        from zoneinfo import ZoneInfo
        try:
            tz = ZoneInfo(timezone)
        except Exception:
            tz = ZoneInfo("America/Sao_Paulo")
        utc = ZoneInfo("UTC")

        events_result = await client.check_availability(
            credentials_config, start_dt, end_dt, calendar_id
        )
        if events_result.get("status") == "error":
            return events_result

        def _to_utc(node):
            dtv = node.get("dateTime")
            if dtv:
                d = datetime.fromisoformat(dtv.replace("Z", "+00:00"))
                if d.tzinfo is None:
                    d = d.replace(tzinfo=tz)
                return d.astimezone(utc)
            dv = node.get("date")
            if dv:
                return datetime.fromisoformat(dv).replace(tzinfo=tz).astimezone(utc)
            return None

        busy_periods = []
        for ev in events_result.get("events", []):
            bs = _to_utc(ev.get("start", {}))
            be = _to_utc(ev.get("end", {}))
            if bs and be:
                busy_periods.append((bs, be))

        logger.info(f"Prefetched {len(busy_periods)} busy events for the whole window (1 API call)")

        def _slot_is_free(s_naive, e_naive):
            s_utc = s_naive.replace(tzinfo=tz).astimezone(utc)
            e_utc = e_naive.replace(tzinfo=tz).astimezone(utc)
            for bs, be in busy_periods:
                if s_utc < be and e_utc > bs:  # overlap
                    return False
            return True

        while current_day <= end_day:
            # Get business hours for this day
            day_names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
            day_name = day_names[current_day.weekday()]
            day_config = business_hours.get(day_name, {})

            logger.debug(f"Checking {day_name} ({current_day.date()}): enabled={day_config.get('enabled') if day_config else False}")

            if not day_config or not day_config.get("enabled"):
                # Skip non-business days
                logger.debug(f"Skipping {day_name} - not a business day")
                current_day += timedelta(days=1)
                continue

            # Parse business hours for this day
            start_time_str = day_config.get("start", "09:00")
            end_time_str = day_config.get("end", "18:00")

            hour, minute = map(int, start_time_str.split(":"))
            day_start = current_day.replace(hour=hour, minute=minute)

            hour, minute = map(int, end_time_str.split(":"))
            day_end = current_day.replace(hour=hour, minute=minute)

            # Ensure we're within the requested range
            if day_start < start_dt:
                day_start = start_dt
            if day_end > end_dt:
                day_end = end_dt

            # Check slots within this day
            slot_start = day_start
            while slot_start + timedelta(minutes=slot_duration) <= day_end:
                slot_end = slot_start + timedelta(minutes=slot_duration)

                # Check if slot meets minimum advance time
                if not client.validate_advance_time(slot_start, min_advance_time, timezone):
                    slot_start += timedelta(minutes=30)  # Move forward in 30-min increments
                    continue

                # Check availability against the pre-fetched events (in memory, no API call)
                if _slot_is_free(slot_start, slot_end):
                    available_slots.append({
                        "start": slot_start.isoformat(),
                        "end": slot_end.isoformat(),
                        "duration_minutes": slot_duration
                    })

                # Move to next slot (30-minute increments for better coverage)
                slot_start += timedelta(minutes=30)

            # Move to next day
            current_day += timedelta(days=1)

        logger.info(f"Found {len(available_slots)} available time slots in range {start_dt} to {end_dt}")

        return {
            "status": "success",
            "message": f"Found {len(available_slots)} available time slots",
            "available_slots": available_slots,
            "search_range": {
                "start": start_dt.isoformat(),
                "end": end_dt.isoformat()
            },
            "slot_duration_minutes": slot_duration
        }

    # Set function metadata
    check_calendar_availability.__name__ = "check_calendar_availability"

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

    check_calendar_availability.__doc__ = f"""Check Google Calendar availability for a time range or find available time slots.

This tool can:
1. Check if a specific time slot is available
2. Find available time slots within a date range
{bh_description}{constraints_description}

IMPORTANT: Always respect the business hours and scheduling constraints above when suggesting meeting times to customers.

Args:
    start_date (str): Start date and time in ISO format (e.g., '2024-01-15T09:00:00') in timezone {timezone}
    end_date (str): End date and time in ISO format (e.g., '2024-01-15T10:00:00') in timezone {timezone}
    calendar_id (str, optional): Calendar ID to check (default: 'primary')
    find_slots (bool, optional): If True, find available time slots instead of just checking if range is free (default: False)
    slot_duration (int, optional): Duration of each time slot in minutes (used when find_slots=True, default: 60)

Examples:
- Check if 2PM-3PM tomorrow is free: start_date='2024-01-16T14:00:00', end_date='2024-01-16T15:00:00'
- Find available 1-hour slots this week: start_date='2024-01-15T00:00:00', end_date='2024-01-21T23:59:59', find_slots=True, slot_duration=60
"""

    return check_calendar_availability
