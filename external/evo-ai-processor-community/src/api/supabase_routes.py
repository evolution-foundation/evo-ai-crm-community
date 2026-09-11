"""
Supabase integration API routes.

Provides endpoints for:
- OAuth authorization flow
- Configuration storage
- Disconnection
"""

import logging
import os
import json
import base64
from typing import Optional, Dict, Any

from fastapi import APIRouter, HTTPException, Depends, status, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from src.services.supabase_service import SupabaseService
from src.config.database import get_db
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import (
    OAuthMetadataResponse, OAuthAuthorizationResponse, OAuthCallbackResponse, 
    IntegrationConfigResponse, DiscoverToolsResponse, DisconnectResponse
)

from src.api.dependencies import get_current_user
from src.middleware.permissions import RequirePermission

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/agents/{agent_id}/integrations/supabase",
    tags=["supabase"],
)

# Callback router for fixed OAuth redirect URL (without account/agent IDs in path)
callback_router = APIRouter(
    prefix="/integrations/supabase",
    tags=["supabase"],
    responses={
        200: {"description": "Authorization completed successfully"},
        422: {"description": "Validation error"},
        500: {"description": "Internal server error"},
    },
)


# Request/Response Models
class AuthorizationResponse(BaseModel):
    """Response model for OAuth authorization."""
    url: str = Field(..., description="OAuth authorization URL")


class CallbackRequest(BaseModel):
    """Request model for OAuth callback."""
    code: str = Field(..., description="Authorization code from OAuth")
    state: str = Field(..., description="State parameter from OAuth")


class CallbackResponse(BaseModel):
    """Response model for OAuth callback."""
    success: bool
    username: Optional[str] = None
    email: Optional[str] = None
    error: Optional[str] = None


# Dependency to get Supabase service
async def get_supabase_service(
    request: Request
) -> SupabaseService:
    """Get Supabase service instance with credentials from global config."""
    from src.services.global_config_service import get_global_config_service

    # Fetch credentials from global config
    config_service = get_global_config_service()
    # Thread the request's tenant (enterprise) into the credential fetch so the
    # CRM resolves the per-tenant BYO credential. None under community/standalone
    # (runtime_context default) → the header is omitted and the call is a no-op.
    from src.evo_extension_points import runtime_context
    cid = runtime_context.current_context_id(request)
    credentials = await config_service.get_supabase_credentials()

    redirect_uri = credentials.get("redirect_uri")

    # Only redirect_uri is required for Supabase OAuth
    # MCP endpoint URL is fixed (discovery will find authorization_url automatically)
    if not redirect_uri:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Supabase OAuth redirect_uri not configured in global_config. "
                   "Please configure: SUPABASE_OAUTH_REDIRECT_URI in the CRM global configuration. "
                   "Note: Supabase OAuth only requires redirect_uri, no client_id/secret needed."
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

    # Supabase MCP endpoint is fixed (not configurable)
    # OAuth discovery will find authorization_url automatically
    mcp_url = "https://mcp.supabase.com/mcp"

    return SupabaseService(
        redirect_uri=redirect_uri,
        core_service_url=core_service_url,
        user_token=user_token,
        mcp_url=mcp_url,
        tenant_id=cid
    )


# API Routes
@router.post(
    "/discover",
    response_model=SuccessResponse[OAuthMetadataResponse],
    responses={
        200: {"description": "OAuth requirements discovered successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def discover_oauth(
    agent_id: str,
    service: SupabaseService = Depends(get_supabase_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Discover OAuth requirements from Supabase MCP server.

    This endpoint follows the MCP OAuth Protected Resource discovery pattern:
    1. Calls the MCP endpoint (expects 401)
    2. Extracts OAuth metadata from .well-known/oauth-protected-resource
    3. Returns OAuth metadata (authorization_servers, scopes_supported, etc.)
    """
    try:
        oauth_metadata = await service.discover_oauth_requirements()
        return success_response(
            data=oauth_metadata,
            message="OAuth requirements discovered successfully"
        )
    except Exception as e:
        logger.error(f"Error discovering OAuth requirements: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to discover OAuth requirements: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


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
    service: SupabaseService = Depends(get_supabase_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Generate OAuth 2.0 authorization URL for Supabase MCP.

    First discovers OAuth requirements from the MCP server, then generates
    the authorization URL using the discovered authorization server and scopes.

    Returns an authorization URL that the user should visit to grant access.
    """
    try:
        url = await service.generate_authorization_url(
            agent_id=agent_id,
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
    response_model=SuccessResponse[OAuthCallbackResponse],
    responses={
        200: {"description": "Authorization completed successfully"},
        422: {"model": ErrorResponse, "description": "Validation error"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def complete_authorization(
    agent_id: str,
    request: CallbackRequest,
    db: Session = Depends(get_db),
    service: SupabaseService = Depends(get_supabase_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Complete OAuth authorization flow and store tokens.

    This endpoint handles the OAuth callback from Supabase.
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
            data={"username": result.get("username"), "email": result.get("email")},
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
    "",
    response_model=SuccessResponse[IntegrationConfigResponse],
    responses={
        200: {"description": "Configuration retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_configuration(
    agent_id: str,
    db: Session = Depends(get_db),
    service: SupabaseService = Depends(get_supabase_service),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """Get Supabase integration configuration. Creates default config if not found."""
    try:
        # Use get_integration_config from mcp_integration_base for direct DB access
        from src.api.mcp_integration_base import get_integration_config

        # Try to load from database first (preferred method)
        config = await get_integration_config(db, agent_id, "supabase", load_from_service=service._load_credentials)

        if not config:
            # Create default configuration if not found
            logger.info(f"Supabase integration not found for agent {agent_id}, creating default config")
            default_config = {
                "provider": "supabase",
                "connected": False,
            }
            # Save default config directly to database
            try:
                from src.services.agent_service import upsert_agent_integration

                success = await upsert_agent_integration(
                    db, agent_id, "supabase", default_config
                )
                if success:
                    logger.info(f"Created default Supabase integration config for agent {agent_id}")
            except Exception as save_error:
                logger.warning(f"Could not save default Supabase config: {save_error}")
                # Return default config anyway

            return success_response(
                data=default_config,
                message="Configuration retrieved successfully"
            )

        # Ensure connected field is correct (should be True if access_token exists)
        # get_integration_config already sets this, but double-check
        has_access_token = bool(config.get("access_token"))
        config["connected"] = has_access_token

        logger.debug(f"Supabase config BEFORE sanitize for agent {agent_id}: has_access_token={has_access_token}, connected={config.get('connected')}, access_token present={bool(config.get('access_token'))}")

        # Sanitize config: remove all sensitive fields (access_token, client_id, etc.)
        from src.api.integrations_routes import sanitize_config
        sanitized_config = sanitize_config(config)

        # Ensure connected is preserved after sanitization (it should be, but double-check)
        sanitized_config["connected"] = has_access_token

        logger.info(f"Supabase config for agent {agent_id}: connected={sanitized_config.get('connected')}, has_access_token={has_access_token}, config keys={list(sanitized_config.keys())}")
        return success_response(
            data=sanitized_config,
            message="Configuration retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error getting Supabase configuration: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to get configuration: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.get(
    "/discover-tools",
    response_model=SuccessResponse[DiscoverToolsResponse],
    responses={
        200: {"description": "Tools discovered successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def discover_tools(
    agent_id: str,
    db: Session = Depends(get_db),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """Discover available MCP tools from Supabase using stored access_token."""
    from src.api.mcp_integration_base import discover_tools_endpoint
    tools = await discover_tools_endpoint(
        agent_id, "supabase", "https://mcp.supabase.com/mcp", db
    )

    return success_response(
        data=tools,
        message="Tools discovered successfully"
    )


@router.put(
    "",
    response_model=SuccessResponse[IntegrationConfigResponse],
    responses={
        200: {"description": "Configuration updated successfully"},
        404: {"model": ErrorResponse, "description": "Integration not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def save_configuration(
    agent_id: str,
    config: Dict[str, Any],
    db: Session = Depends(get_db),
    service: SupabaseService = Depends(get_supabase_service),
    _permission: None = Depends(RequirePermission("integrations", "update")),
    _: dict = Depends(get_current_user),
):
    """Save Supabase integration configuration."""
    try:
        # Load existing configuration from database (preferred) or service (fallback)
        from src.api.mcp_integration_base import get_integration_config

        stored_config = await get_integration_config(db, agent_id, "supabase", load_from_service=service._load_credentials)

        if not stored_config:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Supabase integration not connected. Please connect first via OAuth.",
            status_code=status.HTTP_404_NOT_FOUND
        )

        # Get new config from request (remove 'connected' as it's computed, not stored)
        new_config = config.get("config", {}).copy()
        new_config.pop("connected", None)  # Remove 'connected' as it's computed from access_token

        # Preserve sensitive fields that shouldn't be overwritten by frontend
        sensitive_fields = ["access_token", "client_id", "client_secret", "refresh_token", "pkce_verifiers", "code_verifier"]
        preserved_fields = {k: v for k, v in stored_config.items() if k in sensitive_fields and k not in new_config}

        # Update configuration (merge with existing, preserving sensitive fields)
        updated_config = {**stored_config, **new_config, **preserved_fields}

        # Ensure connected is set correctly based on access_token
        updated_config["connected"] = bool(updated_config.get("access_token"))

        # Save directly to database using upsert_agent_integration
        from src.services.agent_service import upsert_agent_integration

        success = await upsert_agent_integration(
            db, agent_id, "supabase", updated_config
        )

        if not success:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Failed to save configuration to database",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )

        logger.info(f"Saved Supabase configuration for agent {agent_id}: connected={updated_config.get('connected')}")

        # Sanitize config before returning (remove sensitive fields)
        from src.api.integrations_routes import sanitize_config
        sanitized_config = sanitize_config(updated_config.copy())
        sanitized_config["connected"] = updated_config.get("connected", False)

        return success_response(
            data=sanitized_config,
            message="Configuration retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error saving Supabase configuration: {e}", exc_info=True)
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
        200: {"description": "Integration disconnected successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def disconnect(
    agent_id: str,
    service: SupabaseService = Depends(get_supabase_service),
    _permission: None = Depends(RequirePermission("integrations", "disconnect")),
    _: dict = Depends(get_current_user),
):
    """Disconnect Supabase integration."""
    try:
        success = await service.disconnect(agent_id)
        return success_response(
            data={"success": success},
            message="Operation completed successfully"
        )
    except Exception as e:
        logger.error(f"Error disconnecting Supabase: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to disconnect: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


# Fixed OAuth Callback Endpoint (for Supabase OAuth App redirect)
@callback_router.get(
    "/callback",
    response_model=SuccessResponse[OAuthCallbackResponse],
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
    db: Session = Depends(get_db)
):
    """
    OAuth 2.0 callback endpoint for Supabase MCP (fixed URL).

    This endpoint handles the OAuth redirect from Supabase.
    The agent_id is extracted from the state parameter.

    Query Parameters:
        code: Authorization code from Supabase OAuth
        state: Base64-encoded JSON containing agent_id and mcp_url
    """
    try:
        # Decode state to extract agent_id and mcp_url
        state_data = json.loads(
            base64.urlsafe_b64decode(state.encode()).decode()
        )

        agent_id = state_data.get("agent_id")
        mcp_url = state_data.get("mcp_url")

        if not agent_id:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Invalid state parameter: missing agent_id",
            status_code=status.HTTP_400_BAD_REQUEST
        )

        # Get Supabase service instance (create without user token for callback)
        from src.services.global_config_service import get_global_config_service

        config_service = get_global_config_service()
        credentials = await config_service.get_supabase_credentials()

        redirect_uri = credentials.get("redirect_uri")

        # Authorization URL is hardcoded (not configurable)
        authorization_url = "https://api.supabase.com/v1/oauth/authorize"

        # Only redirect_uri is required
        if not redirect_uri:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Supabase OAuth redirect_uri not configured",
            status_code=status.HTTP_400_BAD_REQUEST
        )

        core_service_url = os.getenv("CORE_SERVICE_URL", "http://localhost:5555/api/v1")

        # Create service with empty user_token (not needed for callback)
        service = SupabaseService(
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token="",  # Not needed for callback
            authorization_url=authorization_url,
            mcp_url=mcp_url
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

        return success_response(
            data={"username": result.get("username"), "email": result.get("email")},
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
