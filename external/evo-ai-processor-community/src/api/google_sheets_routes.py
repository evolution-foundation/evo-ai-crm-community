"""
Google Sheets integration API routes.

Provides endpoints for:
- OAuth authorization flow
- Spreadsheet management
- Configuration storage
- Sheet operations
"""

import logging
import os
from typing import Optional, List, Dict, Any

from fastapi import APIRouter, HTTPException, Depends, status, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from src.services.google_sheets_service import GoogleSheetsService
from src.config.database import get_db
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import (
    OAuthAuthorizationResponse, GoogleSheetsCallbackResponse, SpreadsheetsListResponse,
    DisconnectResponse
)

from src.api.dependencies import get_current_user
from src.api.oauth_redirect import derive_redirect_uri
from src.middleware.permissions import RequirePermission

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/agents/{agent_id}/integrations/google-sheets",
    tags=["google-sheets"],
)

# Callback router for fixed OAuth redirect URL (without account/agent IDs in path)
callback_router = APIRouter(
    prefix="/integrations/google-sheets",
    tags=["google-sheets"],
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


class SpreadsheetItem(BaseModel):
    """Spreadsheet item model."""
    id: str
    name: str
    url: Optional[str] = None
    selected: Optional[bool] = False


class CallbackResponse(BaseModel):
    """Response model for OAuth callback."""
    success: bool
    email: Optional[str] = None
    spreadsheets: Optional[List[SpreadsheetItem]] = None
    error: Optional[str] = None


class SpreadsheetsResponse(BaseModel):
    """Response model for spreadsheet list."""
    spreadsheets: List[SpreadsheetItem]


class ConfigurationRequest(BaseModel):
    """Request model for configuration save."""
    provider: str = "google_sheets"
    email: Optional[str] = None
    connected: Optional[bool] = None
    spreadsheets: Optional[List[SpreadsheetItem]] = None
    settings: Optional[Dict[str, Any]] = None


class ConfigurationResponse(BaseModel):
    """Response model for configuration save."""
    success: bool


class DisconnectResponse(BaseModel):
    """Response model for disconnect."""
    success: bool


# Dependency to get Google Sheets service
async def get_google_sheets_service(
    request: Request
) -> GoogleSheetsService:
    """Get Google Sheets service instance with credentials from global config."""
    from src.services.global_config_service import get_global_config_service

    # Fetch credentials from global config
    config_service = get_global_config_service()
    # Thread the request's tenant (enterprise) into the credential fetch so the
    # CRM resolves the per-tenant BYO credential. None under community/standalone
    # (runtime_context default) → the header is omitted and the call is a no-op.
    from src.evo_extension_points import runtime_context
    cid = runtime_context.current_context_id(request)
    credentials = await config_service.get_google_sheets_credentials(tenant_id=cid)

    client_id = credentials.get("client_id")
    client_secret = credentials.get("client_secret")
    redirect_uri = credentials.get("redirect_uri") or derive_redirect_uri(request, "google_sheets")

    if not client_id or not client_secret or not redirect_uri:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Google Sheets OAuth credentials not configured in global_config. "
                   "Please configure: google_sheets_client_id, google_sheets_client_secret, "
                   "google_sheets_redirect_uri in the CRM global configuration."
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

    return GoogleSheetsService(
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
    authorization_request: AuthorizationRequest,
    request: Request,
    service: GoogleSheetsService = Depends(get_google_sheets_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Generate OAuth 2.0 authorization URL for Google Sheets.

    Returns an authorization URL that the user should visit to grant access.
    """
    try:
        url = service.generate_authorization_url(
            agent_id=agent_id,
            email=authorization_request.email
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
    response_model=SuccessResponse[GoogleSheetsCallbackResponse],
    responses={
        200: {"description": "Authorization completed successfully"},
        400: {"model": ErrorResponse, "description": "Bad request"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def complete_authorization(
    agent_id: str,
    callback_request: CallbackRequest,
    request: Request,
    service: GoogleSheetsService = Depends(get_google_sheets_service),
    db: Session = Depends(get_db),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Complete OAuth 2.0 authorization flow.

    Exchanges the authorization code for access tokens and fetches
    available spreadsheets.
    """
    try:
        result = await service.complete_authorization(
            agent_id=agent_id,
            code=callback_request.code,
            state=callback_request.state,
            db=db
        )

        if not result.get("success"):
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
                message=result.get("error", "Unknown error"),
                status_code=status.HTTP_400_BAD_REQUEST
            )

        spreadsheets_data = [SpreadsheetItem(**sheet).model_dump() if isinstance(sheet, dict) else sheet.model_dump() if hasattr(sheet, 'model_dump') else sheet for sheet in result.get("spreadsheets", [])]
        
        return success_response(
            data={
                "email": result.get("email"),
                "spreadsheets": spreadsheets_data
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
    "/spreadsheets",
    response_model=SuccessResponse[SpreadsheetsListResponse],
    responses={
        200: {"description": "Spreadsheets retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Google Sheets not connected"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_spreadsheets(
    agent_id: str,
    service: GoogleSheetsService = Depends(get_google_sheets_service),
    db: Session = Depends(get_db),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """
    Get list of available Google Sheets spreadsheets.

    Returns all spreadsheets accessible by the authenticated user.
    """
    try:
        spreadsheets = await service.get_spreadsheets(
            agent_id=agent_id,
            db=db
        )

        spreadsheets_data = [SpreadsheetItem(**sheet).model_dump() if isinstance(sheet, dict) else sheet.model_dump() if hasattr(sheet, 'model_dump') else sheet for sheet in spreadsheets]
        
        return success_response(
            data={
                "spreadsheets": spreadsheets_data
            },
            message="Spreadsheets retrieved successfully"
        )

    except ValueError as e:
        logger.error(f"No credentials found: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Google Sheets not connected",
            status_code=status.HTTP_404_NOT_FOUND
        )
    except Exception as e:
        logger.error(f"Error fetching spreadsheets: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to fetch spreadsheets: {str(e)}",
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
    config_request: ConfigurationRequest,
    request: Request,
    service: GoogleSheetsService = Depends(get_google_sheets_service),
    _permission: None = Depends(RequirePermission("integrations", "update")),
    _: dict = Depends(get_current_user),
):
    """
    Save Google Sheets configuration.

    Stores spreadsheet selection and settings for the agent.
    """
    try:
        config = config_request.dict(exclude_none=False)

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
    request: Request,
    service: GoogleSheetsService = Depends(get_google_sheets_service),
    _permission: None = Depends(RequirePermission("integrations", "disconnect")),
    _: dict = Depends(get_current_user),
):
    """
    Disconnect Google Sheets integration.

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
        logger.error(f"Error disconnecting Google Sheets: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to disconnect Google Sheets: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


# Fixed OAuth Callback Endpoint (for Google Cloud Console redirect)
@callback_router.get(
    "/callback",
    response_model=SuccessResponse[GoogleSheetsCallbackResponse],
    responses={
        200: {"description": "Authorization completed successfully"},
        422: {"model": ErrorResponse, "description": "Validation error"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def oauth_callback(
    code: str,
    state: str,
    request: Request,
    service: GoogleSheetsService = Depends(get_google_sheets_service),
    db: Session = Depends(get_db)
):
    """
    OAuth 2.0 callback endpoint for Google Sheets (fixed URL).

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

        spreadsheets_data = [SpreadsheetItem(**sheet).model_dump() if isinstance(sheet, dict) else sheet.model_dump() if hasattr(sheet, 'model_dump') else sheet for sheet in result.get("spreadsheets", [])]
        
        return success_response(
            data={
                "email": result.get("email"),
                "spreadsheets": spreadsheets_data
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
