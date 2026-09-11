"""
Google Calendar integration API routes.

Provides endpoints for:
- OAuth authorization flow
- Calendar management
- Configuration storage
- Event operations
"""

import logging
import os
from typing import Optional, List, Dict, Any

from fastapi import APIRouter, HTTPException, Depends, status, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from src.services.google_calendar_service import GoogleCalendarService
from src.config.database import get_db
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import (
    OAuthAuthorizationResponse, GoogleCalendarCallbackResponse, CalendarsListResponse,
    AvailabilityResponse, CreateEventResponse, DisconnectResponse
)

from src.api.dependencies import get_current_user
from src.api.oauth_redirect import derive_redirect_uri
from src.middleware.permissions import RequirePermission

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/agents/{agent_id}/integrations/google-calendar",
    tags=["google-calendar"],
)

# Callback router for fixed OAuth redirect URL (without account/agent IDs in path)
callback_router = APIRouter(
    prefix="/integrations/google-calendar",
    tags=["google-calendar"],
    responses={
        200: {"description": "Authorization completed successfully"},
        422: {"description": "Validation error"},
        500: {"description": "Internal server error"},
    },
)


# Request/Response Models
class AuthorizationRequest(BaseModel):
    """Request model for OAuth authorization."""
    email: Optional[str] = Field(None, description="Optional email hint for OAuth flow")


class AuthorizationResponse(BaseModel):
    """Response model for OAuth authorization."""
    url: str = Field(..., description="OAuth authorization URL")


class CallbackRequest(BaseModel):
    """Request model for OAuth callback."""
    code: str = Field(..., description="Authorization code from OAuth")
    state: str = Field(..., description="State parameter from OAuth")


class CalendarItem(BaseModel):
    """Calendar item model."""
    id: str
    name: str
    email: Optional[str] = None
    primary: Optional[bool] = False
    selected: Optional[bool] = False


class CallbackResponse(BaseModel):
    """Response model for OAuth callback."""
    success: bool
    email: Optional[str] = None
    calendars: Optional[List[CalendarItem]] = None
    error: Optional[str] = None


class CalendarsResponse(BaseModel):
    """Response model for calendar list."""
    calendars: List[CalendarItem]


class ConfigurationRequest(BaseModel):
    """Request model for configuration save."""
    provider: str = "google_calendar"
    email: Optional[str] = None
    connected: Optional[bool] = None
    calendars: Optional[List[CalendarItem]] = None
    settings: Optional[Dict[str, Any]] = None


class ConfigurationResponse(BaseModel):
    """Response model for configuration save."""
    success: bool


class DisconnectResponse(BaseModel):
    """Response model for disconnect."""
    success: bool


class AvailabilityRequest(BaseModel):
    """Request model for availability check."""
    calendarId: str
    start: str = Field(..., description="ISO format datetime")
    end: str = Field(..., description="ISO format datetime")


class AvailabilitySlot(BaseModel):
    """Availability slot model."""
    start: str
    end: str


class AvailabilityResponse(BaseModel):
    """Response model for availability check."""
    available: bool
    slots: Optional[List[AvailabilitySlot]] = None


class EventAttendee(BaseModel):
    """Event attendee model."""
    email: str
    name: Optional[str] = None


class CreateEventRequest(BaseModel):
    """Request model for event creation."""
    calendarId: str
    summary: str
    description: Optional[str] = None
    start: str = Field(..., description="ISO format datetime")
    end: str = Field(..., description="ISO format datetime")
    attendees: Optional[List[EventAttendee]] = None
    meetLink: Optional[bool] = False


class CreateEventResponse(BaseModel):
    """Response model for event creation."""
    success: bool
    eventId: Optional[str] = None
    meetLink: Optional[str] = None


# Dependency to get Google Calendar service
async def get_google_calendar_service(
    request: Request
) -> GoogleCalendarService:
    """Get Google Calendar service instance with credentials from global config."""
    from src.services.global_config_service import get_global_config_service

    # Fetch credentials from global config
    config_service = get_global_config_service()
    # Thread the request's tenant (enterprise) into the credential fetch so the
    # CRM resolves the per-tenant BYO credential. None under community/standalone
    # (runtime_context default) → the header is omitted and the call is a no-op.
    from src.evo_extension_points import runtime_context
    cid = runtime_context.current_context_id(request)
    credentials = await config_service.get_google_calendar_credentials(tenant_id=cid)

    client_id = credentials.get("client_id")
    client_secret = credentials.get("client_secret")
    redirect_uri = credentials.get("redirect_uri") or derive_redirect_uri(request, "google_calendar")

    if not client_id or not client_secret or not redirect_uri:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Google Calendar OAuth credentials not configured in global_config. "
                   "Please configure: google_calendar_client_id, google_calendar_client_secret, "
                   "google_calendar_redirect_uri in the CRM global configuration."
        )

    # Get core service URL from environment
    core_service_url = os.getenv("CORE_SERVICE_URL", "http://localhost:5555/api/v1")

    # Get user token from request headers
    auth_header = request.headers.get("Authorization", "")
    user_token = auth_header.replace("Bearer ", "") if auth_header.startswith("Bearer ") else ""

    if not user_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication token required"
        )

    return GoogleCalendarService(
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        core_service_url=core_service_url,
        user_token=user_token
    )


# API Routes
@router.post(
    "/authorization",
    response_model=SuccessResponse[OAuthAuthorizationResponse],
    responses={
        200: {"description": "Authorization URL generated successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def generate_authorization(
    agent_id: str,
    request: AuthorizationRequest,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Generate OAuth 2.0 authorization URL for Google Calendar.

    Returns an authorization URL that the user should visit to grant access.
    """
    try:
        url = service.generate_authorization_url(
            agent_id=agent_id,
            email=request.email
        )

        return success_response(
            data={"url": url},
            message="Authorization URL generated successfully"
        )

    except Exception as e:
        logger.error(f"Error generating authorization URL: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to generate authorization URL: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.post(
    "/callback",
    response_model=SuccessResponse[GoogleCalendarCallbackResponse],
    responses={
        200: {"description": "Authorization completed successfully"},
        422: {"model": ErrorResponse, "description": "Validation error"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def complete_authorization(
    agent_id: str,
    request: CallbackRequest,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    db: Session = Depends(get_db),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Complete OAuth 2.0 authorization flow.

    Exchanges the authorization code for access tokens and fetches
    available calendars.
    """
    try:
        result = await service.complete_authorization(
            agent_id=agent_id,
            code=request.code,
            state=request.state,
            db=db
        )

        if not result.get("success"):
            return error_response(request=request, code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message=result.get("error", "Unknown error"),
                status_code=status.HTTP_400_BAD_REQUEST
            )

        return success_response(
            data={
                "email": result.get("email"),
                "calendars": [CalendarItem(**cal) for cal in result.get("calendars", [])]
            },
            message="Authorization completed successfully"
        )

    except ValueError as e:
        logger.error(f"Validation error in callback: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_422_UNPROCESSABLE_ENTITY),
            message=str(e),
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY
        )
    except Exception as e:
        logger.error(f"Error completing authorization: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to complete authorization: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.get(
    "/calendars",
    response_model=SuccessResponse[CalendarsListResponse],
    responses={
        200: {"description": "Calendars retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Google Calendar not connected"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_calendars(
    agent_id: str,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    db: Session = Depends(get_db),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """
    Get list of available Google Calendars.

    Returns all calendars accessible by the authenticated user.
    """
    try:
        calendars = await service.get_calendars(
            agent_id=agent_id,
            db=db
        )

        return success_response(
            data=[CalendarItem(**cal) for cal in calendars],
            message="Calendars retrieved successfully"
        )

    except ValueError as e:
        logger.error(f"No credentials found: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Google Calendar not connected",
            status_code=status.HTTP_404_NOT_FOUND
        )
    except Exception as e:
        logger.error(f"Error fetching calendars: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to fetch calendars: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.put(
    "",
    response_model=SuccessResponse[DisconnectResponse],
    responses={
        200: {"description": "Configuration saved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def save_configuration(
    agent_id: str,
    request: ConfigurationRequest,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    _permission: None = Depends(RequirePermission("integrations", "update")),
    _: dict = Depends(get_current_user),
):
    """
    Save Google Calendar configuration.

    Stores calendar selection and settings for the agent.
    """
    try:
        config = request.dict(exclude_none=False)

        await service.save_configuration(
            agent_id=agent_id,
            config=config
        )

        return success_response(
            data={"success": True},
            message="Configuration saved successfully"
        )

    except Exception as e:
        logger.error(f"Error saving configuration: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to save configuration: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.delete(
    "",
    response_model=SuccessResponse[DisconnectResponse],
    responses={
        204: {"description": "Disconnected successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def disconnect(
    agent_id: str,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    _permission: None = Depends(RequirePermission("integrations", "disconnect")),
    _: dict = Depends(get_current_user),
):
    """
    Disconnect Google Calendar integration.

    Revokes access tokens and deletes stored credentials and configuration.
    """
    try:
        await service.disconnect(
            agent_id=agent_id
        )

        return success_response(
            data={"success": True},
            message="Disconnected successfully",
            status_code=204
        )

    except Exception as e:
        logger.error(f"Error disconnecting Google Calendar: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to disconnect Google Calendar: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.post(
    "/availability",
    response_model=SuccessResponse[AvailabilityResponse],
    responses={
        200: {"description": "Availability checked successfully"},
        404: {"model": ErrorResponse, "description": "Google Calendar not connected"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def check_availability(
    agent_id: str,
    request: AvailabilityRequest,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """
    Check calendar availability for a time range.

    Returns whether the calendar is available and lists free time slots.
    """
    try:
        result = await service.check_availability(
            agent_id=agent_id,
            calendar_id=request.calendarId,
            start=request.start,
            end=request.end
        )

        slots_data = [AvailabilitySlot(**slot).model_dump() if isinstance(slot, dict) else slot.model_dump() if hasattr(slot, 'model_dump') else slot for slot in result.get("slots", [])]
        
        return success_response(
            data={
                "available": result["available"],
                "slots": slots_data
            },
            message="Availability checked successfully"
        )

    except ValueError as e:
        logger.error(f"No credentials found: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Google Calendar not connected",
            status_code=status.HTTP_404_NOT_FOUND
        )
    except Exception as e:
        logger.error(f"Error checking availability: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to check availability: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.post(
    "/events",
    response_model=SuccessResponse[CreateEventResponse],
    responses={
        201: {"description": "Event created successfully"},
        404: {"model": ErrorResponse, "description": "Google Calendar not connected"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def create_event(
    agent_id: str,
    request: CreateEventRequest,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    _permission: None = Depends(RequirePermission("integrations", "create")),
    _: dict = Depends(get_current_user),
):
    """
    Create a new calendar event.

    Creates an event with optional Google Meet link and attendees.
    """
    try:
        result = await service.create_event(
            agent_id=agent_id,
            calendar_id=request.calendarId,
            summary=request.summary,
            start=request.start,
            end=request.end,
            description=request.description,
            attendees=[att.dict() for att in request.attendees] if request.attendees else None,
            meet_link=request.meetLink or False
        )

        return success_response(
            data={
                "success": result["success"],
                "eventId": result.get("eventId"),
                "meetLink": result.get("meetLink")
            },
            message="Event created successfully",
            status_code=201
        )

    except ValueError as e:
        logger.error(f"No credentials found: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Google Calendar not connected",
            status_code=status.HTTP_404_NOT_FOUND
        )
    except Exception as e:
        logger.error(f"Error creating event: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to create event: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


# Fixed OAuth Callback Endpoint (for Google Cloud Console redirect)
@callback_router.get(
    "/callback",
    response_model=SuccessResponse[GoogleCalendarCallbackResponse],
    responses={
        200: {"description": "Authorization completed successfully"},
        422: {"model": ErrorResponse, "description": "Validation error"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def oauth_callback(
    code: str,
    state: str,
    service: GoogleCalendarService = Depends(get_google_calendar_service),
    db: Session = Depends(get_db)
):
    """
    OAuth 2.0 callback endpoint for Google Calendar (fixed URL).

    This endpoint handles the OAuth redirect from Google Cloud Console.
    The agent_id is extracted from the state parameter.

    Query Parameters:
        code: Authorization code from Google OAuth
        state: Base64-encoded JSON containing agent_id
    """
    try:
        # Decode state to extract agent_id
        import base64
        import json

        state_data = json.loads(
            base64.urlsafe_b64decode(state.encode()).decode()
        )

        agent_id = state_data.get("agent_id")

        if not agent_id:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid state parameter: missing agent_id",
            status_code=status.HTTP_400_BAD_REQUEST
        )

        # Complete authorization using extracted IDs
        result = await service.complete_authorization(
            agent_id=agent_id,
            code=code,
            state=state,
            db=db
        )

        if not result.get("success"):
            return error_response(request=request, code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message=result.get("error", "Unknown error"),
                status_code=status.HTTP_400_BAD_REQUEST
            )

        calendars_data = [CalendarItem(**cal).model_dump() if isinstance(cal, dict) else cal.model_dump() if hasattr(cal, 'model_dump') else cal for cal in result.get("calendars", [])]

        return success_response(
            data={
                "email": result.get("email"),
                "calendars": calendars_data
            },
            message="Authorization completed successfully"
        )

    except ValueError as e:
        logger.error(f"Validation error in callback: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_422_UNPROCESSABLE_ENTITY),
            message=str(e),
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY
        )
    except Exception as e:
        logger.error(f"Error completing authorization: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to complete authorization: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
