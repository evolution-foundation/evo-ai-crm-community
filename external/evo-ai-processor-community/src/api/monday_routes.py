"""
Monday integration API routes.

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
import httpx
from fastapi import APIRouter, HTTPException, Depends, status, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from src.services.monday_service import MondayService
from src.config.database import get_db
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import (
    OAuthMetadataResponse, OAuthAuthorizationResponse, OAuthCallbackResponse, 
    IntegrationConfigResponse, DiscoverToolsResponse, DisconnectResponse
)

from src.api.dependencies import get_current_user
from src.api.oauth_redirect import derive_redirect_uri
from src.middleware.permissions import RequirePermission

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/agents/{agent_id}/integrations/monday",
    tags=["monday"],
)

# Callback router for fixed OAuth redirect URL (without account/agent IDs in path)
callback_router = APIRouter(
    prefix="/integrations/monday",
    tags=["monday"],
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


# Dependency to get Monday service
async def get_monday_service(
    request: Request
) -> MondayService:
    """Get Monday service instance with credentials from global config."""
    from src.services.global_config_service import get_global_config_service

    # Fetch credentials from global config
    config_service = get_global_config_service()
    # Thread the request's tenant (enterprise) into the credential fetch so the
    # CRM resolves the per-tenant BYO credential. None under community/standalone
    # (runtime_context default) → the header is omitted and the call is a no-op.
    from src.evo_extension_points import runtime_context
    cid = runtime_context.current_context_id(request)
    credentials = await config_service.get_monday_credentials(tenant_id=cid)

    client_id = credentials.get("client_id")  # Optional - can be obtained via dynamic registration
    client_secret = credentials.get("client_secret")  # Optional - can be obtained via dynamic registration
    redirect_uri = credentials.get("redirect_uri") or derive_redirect_uri(request, "monday")

    # Only redirect_uri is required - client_id and client_secret can be obtained via dynamic registration (RFC 7591)
    if not redirect_uri:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Monday OAuth redirect_uri not configured in global_config. "
                   "Please configure: MONDAY_OAUTH_REDIRECT_URI in the CRM global configuration. "
                   "Note: client_id and client_secret are optional and will be obtained via dynamic registration if not provided."
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

    return MondayService(
        redirect_uri=redirect_uri,
        core_service_url=core_service_url,
        user_token=user_token,
        client_id=client_id,  # Optional
        client_secret=client_secret,  # Optional
        tenant_id=cid
    )


async def get_monday_service_optional(
    request: Request
) -> Optional[MondayService]:
    """Get Monday service instance, returning None if credentials are not configured."""
    try:
        return await get_monday_service(request)
    except HTTPException as e:
        if e.status_code == status.HTTP_500_INTERNAL_SERVER_ERROR:
            logger.warning(f"Monday service not available: {e.detail}")
            return None
        raise


# API Routes
@router.get(
    "/discover",
    response_model=SuccessResponse[OAuthMetadataResponse],
    responses={
        200: {"description": "OAuth requirements discovered successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def discover_oauth_requirements(
    agent_id: str,
    service: MondayService = Depends(get_monday_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Discover OAuth requirements from Monday MCP server.

    This endpoint follows the MCP OAuth Protected Resource discovery pattern:
    1. Calls the MCP endpoint (expects 401)
    2. Extracts OAuth metadata from .well-known/oauth-protected-resource
    3. Returns OAuth metadata (authorization_servers, scopes_supported, etc.)
    """
    try:
        metadata = await service.discover_oauth_requirements()
        return success_response(
            data=metadata,
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
    service: MondayService = Depends(get_monday_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Generate OAuth 2.0 authorization URL for Monday MCP.

    First discovers OAuth requirements from the MCP server, then generates
    the authorization URL using the discovered authorization server and scopes.

    Returns an authorization URL that the user should visit to grant access.
    """
    try:
        url = await service.generate_authorization_url(
            agent_id=agent_id
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
    service: MondayService = Depends(get_monday_service),
    _permission: None = Depends(RequirePermission("integrations", "connect")),
    _: dict = Depends(get_current_user),
):
    """
    Complete OAuth authorization flow and store tokens.

    This endpoint handles the OAuth callback from Monday.
    """
    try:
        # Load code_verifier from storage before completing authorization
        # Monday is a public client and requires PKCE, so we need the code_verifier
        stored_code_verifier = None
        try:
            from src.services.agent_service import get_agent_integrations
            integrations = await get_agent_integrations(db, agent_id)
            for integration in integrations:
                if integration.get("provider", "").lower() == "monday":
                    stored_config = integration.get("config", {})
                    pkce_verifiers = stored_config.get("pkce_verifiers", {})
                    stored_code_verifier = pkce_verifiers.get(request.state)
                    break
        except Exception as load_error:
            logger.warning(f"Could not load code_verifier for POST callback: {load_error}")
        
        result = await service.complete_authorization(
            agent_id=agent_id,
            code=request.code,
            state=request.state,
            code_verifier=stored_code_verifier,
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
    service: Optional[MondayService] = Depends(get_monday_service_optional),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """Get Monday integration configuration. Creates default config if not found."""
    try:
        # Use get_integration_config from mcp_integration_base for direct DB access
        from src.api.mcp_integration_base import get_integration_config
        
        # Try to load from database first (preferred method)
        load_from_service = service._load_credentials if service else None
        config = await get_integration_config(db, agent_id, "monday", load_from_service=load_from_service)
        
        if not config:
            # Return default disconnected state
            return success_response(
                data={"provider": "monday", "connected": False},
                message="Configuration retrieved successfully"
            )
        
        # Ensure connected field is correct (should be True if access_token exists)
        # get_integration_config already sets this, but double-check
        has_access_token = bool(config.get("access_token"))
        config["connected"] = has_access_token
        
        logger.debug(f"Monday config BEFORE sanitize for agent {agent_id}: has_access_token={has_access_token}, connected={config.get('connected')}, access_token present={bool(config.get('access_token'))}")
        
        # Sanitize config: remove all sensitive fields (access_token, client_id, etc.)
        from src.api.integrations_routes import sanitize_config
        sanitized_config = sanitize_config(config)
        
        # Ensure connected is preserved after sanitization (it should be, but double-check)
        sanitized_config["connected"] = has_access_token
        
        logger.info(f"Monday config for agent {agent_id}: connected={sanitized_config.get('connected')}, has_access_token={has_access_token}, config keys={list(sanitized_config.keys())}")
        return success_response(
            data=sanitized_config,
            message="Configuration retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error getting Monday configuration: {e}")
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
    service: Optional[MondayService] = Depends(get_monday_service_optional),
    _permission: None = Depends(RequirePermission("integrations", "read")),
    _: dict = Depends(get_current_user),
):
    """Discover available MCP tools from Monday using stored access_token."""
    from src.api.mcp_integration_base import discover_tools_endpoint

    # Pass load_from_service as fallback if service is available
    load_from_service = service._load_credentials if service else None

    tools = await discover_tools_endpoint(
        agent_id, "monday", "https://mcp.monday.com/mcp", db, load_from_service=load_from_service
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
async def update_configuration(
    agent_id: str,
    config: Dict[str, Any],
    db: Session = Depends(get_db),
    service: MondayService = Depends(get_monday_service),
    _permission: None = Depends(RequirePermission("integrations", "update")),
    _: dict = Depends(get_current_user),
):
    """Save Monday integration configuration."""
    try:
        # Load existing configuration from database (preferred) or service (fallback)
        from src.api.mcp_integration_base import get_integration_config

        stored_config = await get_integration_config(db, agent_id, "monday", load_from_service=service._load_credentials)
        
        if not stored_config:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
            message="Monday integration not found. Please complete OAuth flow first.",
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
            db, agent_id, "monday", updated_config
        )

        if not success:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message="Failed to save configuration to database",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
        
        logger.info(f"Saved Monday configuration for agent {agent_id}: connected={updated_config.get('connected')}")
        
        # Sanitize config before returning (remove sensitive fields)
        from src.api.integrations_routes import sanitize_config
        sanitized_config = sanitize_config(updated_config.copy())
        sanitized_config["connected"] = updated_config.get("connected", False)
        
        return success_response(
            data=sanitized_config,
            message="Configuration retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error updating Monday configuration: {e}", exc_info=True)
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to update configuration: {str(e)}",
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
    service: MondayService = Depends(get_monday_service),
    _permission: None = Depends(RequirePermission("integrations", "disconnect")),
    _: dict = Depends(get_current_user),
):
    """Disconnect Monday integration."""
    try:
        success = await service.disconnect(agent_id)
        return success_response(
            data={"success": success},
            message="Operation completed successfully"
        )
    except Exception as e:
        logger.error(f"Error disconnecting Monday: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to disconnect: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


# Fixed OAuth Callback Endpoint (for Monday OAuth App redirect)
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
    OAuth 2.0 callback endpoint for Monday MCP (fixed URL).

    This endpoint handles the OAuth redirect from Monday.
    The agent_id is extracted from the state parameter.

    Query Parameters:
        code: Authorization code from Monday OAuth
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

        # Get Monday service instance (create without user token for callback)
        from src.services.global_config_service import get_global_config_service
        
        config_service = get_global_config_service()
        credentials = await config_service.get_monday_credentials()
        
        client_id = credentials.get("client_id")
        client_secret = credentials.get("client_secret")
        redirect_uri = credentials.get("redirect_uri")
        
        if not redirect_uri:
            return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_400_BAD_REQUEST),
            message="Monday OAuth credentials not configured",
            status_code=status.HTTP_400_BAD_REQUEST
        )
        
        core_service_url = os.getenv("CORE_SERVICE_URL", "http://localhost:5555/api/v1")
        
        # Try to load stored client credentials first (from previous dynamic registration)
        # This is important because dynamic registration may have stored credentials
        stored_client_id = None
        stored_client_secret = None
        stored_auth_method = None
        stored_code_verifier = None
        try:
            integration_url = f"{core_service_url}/agents/{agent_id}/integrations/monday"
            async with httpx.AsyncClient(timeout=10.0) as http_client:
                integration_response = await http_client.get(integration_url)
                if integration_response.status_code == 200:
                    integration_data = integration_response.json()
                    stored_config = integration_data.get("config", {})
                    stored_client_id = stored_config.get("client_id")
                    stored_client_secret = stored_config.get("client_secret")
                    stored_auth_method = stored_config.get("token_endpoint_auth_method")
                    
                    # Try to load code_verifier from pkce_verifiers dict
                    pkce_verifiers = stored_config.get("pkce_verifiers", {})
                    stored_code_verifier = pkce_verifiers.get(state)
                    
                    logger.info(
                        f"Loaded stored Monday credentials: "
                        f"client_id={'set' if stored_client_id else 'not set'}, "
                        f"auth_method={stored_auth_method}, "
                        f"code_verifier={'set' if stored_code_verifier else 'not set'}"
                    )
        except Exception as load_error:
            logger.debug(f"Could not load stored Monday credentials: {load_error}")
        
        # Use stored credentials if available, otherwise use global config
        effective_client_id = stored_client_id or client_id
        effective_client_secret = stored_client_secret or client_secret
        
        # Create service with empty user_token (not needed for callback)
        # client_id and client_secret are optional - will be loaded from storage if not provided
        service = MondayService(
            client_id=effective_client_id,
            client_secret=effective_client_secret,
            redirect_uri=redirect_uri,
            core_service_url=core_service_url,
            user_token="",  # Not needed for callback
            mcp_url=mcp_url
        )
        
        # Set auth method if we loaded it from storage
        if stored_auth_method:
            service._token_endpoint_auth_method = stored_auth_method
        
        logger.info(
            f"Monday callback: agent_id={agent_id}, "
            f"client_id={'set' if effective_client_id else 'not set'}, "
            f"client_secret={'set' if effective_client_secret else 'not set'}, "
            f"auth_method={stored_auth_method or 'none'}"
        )

        # Complete authorization using extracted IDs
        logger.info(
            f"Monday callback: Starting authorization completion. "
            f"agent_id={agent_id}, "
            f"code_length={len(code) if code else 0}, "
            f"state_length={len(state) if state else 0}, "
            f"code_verifier={'set' if stored_code_verifier else 'not set'}"
        )
        
        result = await service.complete_authorization(
            agent_id=agent_id,
            code=code,
            state=state,
            code_verifier=stored_code_verifier,
            db=db
        )

        logger.info(
            f"Monday callback: Authorization completed. "
            f"success={result.get('success')}, "
            f"error={result.get('error', 'none')}, "
            f"username={result.get('username')}, "
            f"email={result.get('email')}"
        )
        
        # Verify that credentials were saved
        if result.get("success"):
            try:
                credentials = await service._load_credentials(agent_id)
                if credentials:
                    has_token = bool(credentials.get("access_token"))
                    logger.info(
                        f"Monday callback: Credentials verification. "
                        f"has_access_token={has_token}, "
                        f"config_keys={list(credentials.keys())}"
                    )
                    if not has_token:
                        logger.error(
                            f"Monday callback: WARNING - Authorization succeeded but access_token was not saved! "
                            f"Config: {credentials}"
                        )
                else:
                    logger.error(
                        f"Monday callback: WARNING - Authorization succeeded but no credentials found!"
                    )
            except Exception as verify_error:
                logger.error(f"Monday callback: Error verifying credentials: {verify_error}")

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

