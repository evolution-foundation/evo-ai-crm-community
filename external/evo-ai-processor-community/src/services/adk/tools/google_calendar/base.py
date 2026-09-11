"""Base client for Google Calendar integration tools."""

import os
from typing import Any, Dict, Optional, List
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError


class GoogleCalendarClient:
    """Client for Google Calendar API with integration configuration."""

    def __init__(self, db=None):
        """
        Initialize Google Calendar client.

        Args:
            db: Database session for direct database access (bypasses API sanitization)
        """
        self.db = db
        self._integration_cache: Dict[str, Dict[str, Any]] = {}

    async def get_integration(
        self,
        agent_id: str
    ) -> Optional[Dict[str, Any]]:
        """
        Fetch Google Calendar integration configuration for an agent directly from database.

        Args:
            agent_id: The agent ID

        Returns:
            Integration configuration with credentials and settings, or None if not found
        """
        cache_key = agent_id
        if cache_key in self._integration_cache:
            return self._integration_cache[cache_key]

        # Load directly from database (no sanitization)
        from src.services.agent_service import get_agent_integration_by_provider

        integration_config = await get_agent_integration_by_provider(
            self.db, agent_id, "google_calendar"
        )

        if integration_config:
            integration = {
                "provider": "google_calendar",
                "config": integration_config
            }
            self._integration_cache[cache_key] = integration
            return integration

        return None

    def _create_credentials(self, credentials_dict: Dict[str, Any]) -> Credentials:
        """
        Create Google OAuth credentials from stored credentials.

        Args:
            credentials_dict: Dictionary with OAuth tokens

        Returns:
            Google OAuth2 Credentials object
        """
        # Support both 'token' and 'access_token' formats
        access_token = credentials_dict.get("token") or credentials_dict.get("access_token")

        return Credentials(
            token=access_token,
            refresh_token=credentials_dict.get("refresh_token"),
            token_uri=credentials_dict.get("token_uri", "https://oauth2.googleapis.com/token"),
            client_id=credentials_dict.get("client_id"),
            client_secret=credentials_dict.get("client_secret"),
            scopes=credentials_dict.get("scopes", [
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/calendar.events"
            ])
        )

    def get_calendar_service(self, credentials_dict: Dict[str, Any]):
        """
        Create Google Calendar API service instance.

        Args:
            credentials_dict: Dictionary with OAuth tokens

        Returns:
            Google Calendar API service
        """
        credentials = self._create_credentials(credentials_dict)
        return build('calendar', 'v3', credentials=credentials)

    def is_within_business_hours(
        self,
        dt: datetime,
        business_hours: Dict[str, Any]
    ) -> bool:
        """
        Check if a datetime falls within configured business hours.

        Args:
            dt: Datetime to check
            business_hours: Business hours configuration

        Returns:
            True if within business hours, False otherwise
        """
        if not business_hours or not business_hours.get("enabled"):
            return True

        # Get day of week (0 = Monday, 6 = Sunday)
        day_names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        day_name = day_names[dt.weekday()]

        day_config = business_hours.get(day_name, {})
        if not day_config.get("enabled"):
            return False

        # Check time range
        start_time = day_config.get("start", "09:00")
        end_time = day_config.get("end", "18:00")

        current_time = dt.strftime("%H:%M")

        return start_time <= current_time <= end_time

    def validate_advance_time(
        self,
        event_time: datetime,
        min_advance_time: int,
        timezone_str: str = "America/Sao_Paulo"
    ) -> bool:
        """
        Check if event respects minimum advance time.

        Args:
            event_time: Proposed event datetime (timezone-naive, assumed to be in agent timezone)
            min_advance_time: Minimum hours in advance
            timezone_str: Agent timezone (default: America/Sao_Paulo)

        Returns:
            True if advance time is sufficient, False otherwise
        """
        if min_advance_time <= 0:
            return True

        # Get current time in agent's timezone
        tz = ZoneInfo(timezone_str)
        now_in_tz = datetime.now(tz)

        # If event_time is naive, make it aware in agent's timezone
        if event_time.tzinfo is None:
            event_time_aware = event_time.replace(tzinfo=tz)
        else:
            event_time_aware = event_time

        min_allowed_time = now_in_tz + timedelta(hours=min_advance_time)
        return event_time_aware >= min_allowed_time

    def validate_max_duration(
        self,
        duration_minutes: int,
        max_duration: int
    ) -> bool:
        """
        Check if event duration is within maximum allowed.

        Args:
            duration_minutes: Proposed event duration in minutes
            max_duration: Maximum allowed duration in minutes

        Returns:
            True if duration is valid, False otherwise
        """
        if max_duration <= 0:
            return True

        return duration_minutes <= max_duration

    async def check_availability(
        self,
        credentials_config: Dict[str, Any],
        start_time: datetime,
        end_time: datetime,
        calendar_id: str = "primary"
    ) -> Dict[str, Any]:
        """
        Check calendar availability for a time range.

        Args:
            credentials_config: Google Calendar credentials configuration
            start_time: Start of time range
            end_time: End of time range
            calendar_id: Calendar ID to check (default: primary)

        Returns:
            Dictionary with availability information
        """

        try:
            service = self.get_calendar_service(credentials_config)

            # Query events in the time range
            events_result = service.events().list(
                calendarId=calendar_id,
                timeMin=start_time.isoformat() + 'Z',
                timeMax=end_time.isoformat() + 'Z',
                singleEvents=True,
                orderBy='startTime'
            ).execute()

            events = events_result.get('items', [])

            return {
                "status": "success",
                "available": len(events) == 0,
                "events": events
            }

        except HttpError as e:
            return {
                "status": "error",
                "message": f"Google Calendar API error: {str(e)}"
            }

    async def create_event(
        self,
        credentials_config: Dict[str, Any],
        config: Dict[str, Any],
        summary: str,
        start_time: datetime,
        end_time: datetime,
        description: str = "",
        attendees: Optional[List[str]] = None,
        calendar_id: str = "primary"
    ) -> Dict[str, Any]:
        """
        Create a calendar event.

        Args:
            credentials_config: Google Calendar credentials configuration
            config: Google Calendar settings configuration
            summary: Event title
            start_time: Event start time
            end_time: Event end time
            description: Event description
            attendees: List of attendee email addresses
            calendar_id: Calendar ID (default: primary)

        Returns:
            Dictionary with created event information
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

        # Validate configuration constraints
        business_hours = get_config_value("businessHours", {})
        if not self.is_within_business_hours(start_time, business_hours):
            return {
                "status": "error",
                "message": "Event time is outside business hours"
            }

        timezone_str = get_config_value("timezone", "America/Sao_Paulo")
        min_advance_time = get_config_value("minAdvanceTime", 0)
        if not self.validate_advance_time(start_time, min_advance_time, timezone_str):
            return {
                "status": "error",
                "message": f"Event must be scheduled at least {min_advance_time} hours in advance"
            }

        duration_minutes = int((end_time - start_time).total_seconds() / 60)
        max_duration = get_config_value("maxDuration", 0)
        if not self.validate_max_duration(duration_minutes, max_duration):
            return {
                "status": "error",
                "message": f"Event duration exceeds maximum of {max_duration} minutes"
            }

        try:
            service = self.get_calendar_service(credentials_config)

            # Build event
            event = {
                'summary': summary,
                'description': description,
                'start': {
                    'dateTime': start_time.isoformat(),
                    'timeZone': get_config_value('timezone', 'America/Sao_Paulo'),
                },
                'end': {
                    'dateTime': end_time.isoformat(),
                    'timeZone': get_config_value('timezone', 'America/Sao_Paulo'),
                },
            }

            # Add attendees if provided
            if attendees:
                event['attendees'] = [{'email': email} for email in attendees]

            # Add Google Meet if configured
            enable_google_meet = get_config_value("enableGoogleMeet", False)
            if enable_google_meet:
                event['conferenceData'] = {
                    'createRequest': {
                        'requestId': f"meet-{int(start_time.timestamp() * 1000)}",
                        'conferenceSolutionKey': {'type': 'hangoutsMeet'}
                    }
                }

            # Create event
            send_invitations = get_config_value("sendInvitations", False)
            created_event = service.events().insert(
                calendarId=calendar_id,
                body=event,
                conferenceDataVersion=1 if enable_google_meet else 0,
                sendUpdates='all' if send_invitations else 'none'
            ).execute()

            return {
                "status": "success",
                "message": "Event created successfully",
                "event": {
                    "id": created_event.get('id'),
                    "summary": created_event.get('summary'),
                    "start": created_event['start'].get('dateTime'),
                    "end": created_event['end'].get('dateTime'),
                    "link": created_event.get('htmlLink'),
                    "meet_link": created_event.get('conferenceData', {}).get('entryPoints', [{}])[0].get('uri')
                }
            }

        except HttpError as e:
            return {
                "status": "error",
                "message": f"Google Calendar API error: {str(e)}"
            }
