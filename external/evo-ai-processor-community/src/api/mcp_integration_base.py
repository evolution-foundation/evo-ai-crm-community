"""
Base utilities for MCP integration routes.

This module provides shared functionality for all MCP integrations to reduce code duplication.
Each integration route should only contain provider-specific logic.
"""

import logging
from typing import Dict, Any, Optional, Callable
from fastapi import APIRouter, HTTPException, Depends, status
from sqlalchemy.orm import Session

from src.api.dependencies import get_current_user
from src.config.database import get_db
from src.api.integrations_routes import sanitize_config
from src.services.agent_service import get_agent_integrations
from src.utils.mcp_discovery import _discover_async
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import IntegrationConfigResponse, DiscoverToolsResponse

logger = logging.getLogger(__name__)


async def get_integration_config(
    db: Session,
    agent_id: str,
    provider: str,
    load_from_service: Optional[Callable] = None
) -> Dict[str, Any]:
    """
    Get integration configuration from database or service.

    Args:
        db: Database session
        agent_id: Agent ID
        provider: Provider name (e.g., 'stripe', 'github')
        load_from_service: Optional service method to load credentials (for backward compatibility)

    Returns:
        Configuration dictionary with 'connected' field set based on access_token presence
    """
    # Try to load from database first (preferred method)
    integrations = await get_agent_integrations(db, agent_id)

    config = None
    for integration in integrations:
        if integration.get("provider", "").lower() == provider.lower():
            config = integration.get("config", {})
            break

    # Fallback to service method if database doesn't have it
    if not config and load_from_service:
        logger.debug(f"Config not found in DB for {provider}, loading from service")
        config = await load_from_service(agent_id)
    
    # Set connected status based on access_token presence
    if config:
        has_access_token = bool(config.get("access_token"))
        config["connected"] = has_access_token
        logger.debug(f"{provider} config loaded: has_access_token={has_access_token}, connected={config.get('connected')}, config keys={list(config.keys())}")
    
    return config


async def get_configuration_endpoint(
    agent_id: str,
    provider: str,
    db: Session,
    load_from_service: Optional[Callable] = None
) -> Dict[str, Any]:
    """
    Standard GET /configuration endpoint for MCP integrations.

    Returns sanitized configuration without sensitive fields.
    """
    try:
        config = await get_integration_config(db, agent_id, provider, load_from_service)
        
        if not config:
            return success_response(
                data={"provider": provider, "connected": False},
                message="Configuration retrieved successfully"
            )
        
        # Sanitize config: remove all sensitive fields
        sanitized_config = sanitize_config(config)
        
        logger.info(
            f"{provider.upper()} config for agent {agent_id}: "
            f"connected={sanitized_config.get('connected')}"
        )
        
        return success_response(
            data=sanitized_config,
            message="Configuration retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error getting {provider} configuration: {e}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Failed to get configuration: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


async def discover_tools_endpoint(
    agent_id: str,
    provider: str,
    mcp_url: str,
    db: Session,
    load_from_service: Optional[Callable] = None
) -> Dict[str, Any]:
    """
    Standard GET /discover-tools endpoint for MCP integrations.

    Discovers tools using stored access_token from database.
    Automatically refreshes token if expired for providers that support refresh tokens.
    """
    try:
        logger.info(
            f"Discover Tools - Starting discovery for {provider.upper()}:\n"
            f"  - Agent ID: {agent_id}\n"
            f"  - MCP URL: {mcp_url}\n"
            f"  - Has load_from_service: {bool(load_from_service)}"
        )

        # Get integration config from database (with service fallback if provided)
        config = await get_integration_config(db, agent_id, provider, load_from_service=load_from_service)
        
        if not config:
            logger.warning(
                f"❌ Discover Tools - No {provider} integration found for agent {agent_id}"
            )
            return success_response(
                data=[],
                message="No integration found"
            )
        
        access_token = config.get("access_token")
        stored_mcp_url = config.get("mcp_url", mcp_url)
        
        # Enhanced logging for Stripe
        if provider.lower() == "stripe":
            logger.info(
                f"🔍 Stripe Discover Tools - Config loaded:\n"
                f"  - Has access_token: {bool(access_token)}\n"
                f"  - Token length: {len(access_token) if access_token else 0}\n"
                f"  - Token preview: {access_token[:15] + '...' + access_token[-10:] if access_token and len(access_token) > 25 else (access_token[:20] if access_token else 'N/A')}\n"
                f"  - Stored MCP URL: {stored_mcp_url}\n"
                f"  - Config keys: {list(config.keys())}\n"
                f"  - Has refresh_token: {bool(config.get('refresh_token'))}\n"
                f"  - Has expires_at: {bool(config.get('expires_at'))}"
            )
            
            # Check token expiration
            expires_at = config.get("expires_at")
            if expires_at and access_token:
                from datetime import datetime
                try:
                    if isinstance(expires_at, str):
                        expires_dt = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                    else:
                        expires_dt = expires_at
                    
                    now = datetime.utcnow()
                    if expires_dt.tzinfo:
                        now = now.replace(tzinfo=expires_dt.tzinfo)
                    
                    if expires_dt < now:
                        logger.error(
                            f"⚠️ Stripe Discover Tools - Token is EXPIRED!\n"
                            f"  - Expires at: {expires_at}\n"
                            f"  - Current time: {now.isoformat()}\n"
                            f"  - This will cause 'Session terminated' error"
                        )
                    else:
                        time_until_expiry = expires_dt - now
                        logger.info(
                            f"ℹ️ Stripe Discover Tools - Token expires in: {time_until_expiry}"
                        )
                except Exception as e:
                    logger.warning(f"Could not parse expires_at: {expires_at}, error: {e}")
        
        logger.debug(f"Discovering {provider} tools: has_access_token={bool(access_token)}, mcp_url={stored_mcp_url}")
        
        if not access_token:
            logger.error(
                f"❌ Discover Tools - No access_token found for {provider} integration (agent {agent_id})\n"
                f"  - Config keys: {list(config.keys())}\n"
                f"  - This will cause 'Session terminated' error"
            )
            return success_response(
                data=[],
                message="No integration found"
            )
        
        # Validate token format for Stripe
        if provider.lower() == "stripe" and access_token.startswith(("sk_", "rk_", "pk_")):
            logger.error(
                f"❌ Stripe Discover Tools - REST API key detected instead of OAuth token!\n"
                f"  - Token starts with: {access_token[:4]}\n"
                f"  - Stripe MCP requires OAuth access token, not REST API keys\n"
                f"  - This will cause 'Session terminated' error"
            )
            return success_response(
                data=[],
                message="Invalid token format"
            )
        
        # Try to refresh token if provider supports it (HubSpot, etc.)
        # For HubSpot, use get_hubspot_mcp_config which handles refresh automatically
        if provider.lower() == "hubspot":
            try:
                from src.services.adk.mcp_servers.hubspot.config import get_hubspot_mcp_config
                hubspot_config = await get_hubspot_mcp_config(
                    agent_id=agent_id,
                    db=db
                )
                if hubspot_config and hubspot_config.get("headers", {}).get("Authorization"):
                    # Extract token from Bearer header
                    auth_header = hubspot_config["headers"]["Authorization"]
                    if auth_header.startswith("Bearer "):
                        access_token = auth_header.replace("Bearer ", "")
                        stored_mcp_url = hubspot_config.get("url", stored_mcp_url)
                        logger.info(
                            f"HubSpot token refreshed via get_hubspot_mcp_config for discover-tools. "
                            f"New token length: {len(access_token)}"
                        )
            except Exception as refresh_error:
                logger.warning(
                    f"Failed to refresh HubSpot token during discover-tools: {refresh_error}. "
                    f"Using existing token (may be expired)."
                )
        
        # Discover tools using stored access_token (or refreshed token)
        logger.info(
            f"🔍 Discover Tools - Calling _discover_async for {provider}:\n"
            f"  - URL: {stored_mcp_url}\n"
            f"  - Has Authorization header: True\n"
            f"  - Token length: {len(access_token)}"
        )
        
        mcp_config = {
            "url": stored_mcp_url,
            "headers": {
                "Authorization": f"Bearer {access_token}"
            }
        }
        
        tools = await _discover_async(mcp_config)
        
        logger.info(
            f"✅ Discover Tools - Successfully discovered {len(tools)} tools from {provider} MCP for agent {agent_id}"
        )
        return success_response(
            data=tools,
            message=f"Discovered {len(tools)} tools successfully"
        )
        
    except Exception as e:
        logger.error(f"Error discovering {provider} tools: {e}", exc_info=True)
        return success_response(
            data=[],
            message="Error discovering tools"
        )


def create_mcp_router(
    provider: str,
    prefix: str,
    tags: list,
    service_class: Optional[type] = None,
    get_service_func: Optional[Callable] = None,
    get_service_optional_func: Optional[Callable] = None,
    mcp_url: str = None
) -> APIRouter:
    """
    Create a standardized router for an MCP integration.
    
    Args:
        provider: Provider name (e.g., 'stripe', 'github')
        prefix: Router prefix (e.g., '/agents/{agent_id}/integrations/stripe')
        tags: Router tags
        service_class: Optional service class (for type hints)
        get_service_func: Optional function to get service instance
        get_service_optional_func: Optional function to get service instance (can return None)
        mcp_url: Default MCP URL for this provider
        
    Returns:
        Configured FastAPI router with standard endpoints
    """
    router = APIRouter(prefix=prefix, tags=tags,)
    
    # Add GET /configuration endpoint
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
        _: dict = Depends(get_current_user)
    ):
        """Get integration configuration."""
        load_from_service = None
        if get_service_optional_func:
            from fastapi import Request
            request = Request({})
            service = get_service_optional_func(request)
            if service and hasattr(service, '_load_credentials'):
                load_from_service = service._load_credentials

        config = await get_configuration_endpoint(
            agent_id, provider, db, load_from_service
        )

        return success_response(
            data=config,
            message="Configuration retrieved successfully"
        )

    # Add GET /discover-tools endpoint if MCP URL is provided
    if mcp_url:
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
            _: dict = Depends(get_current_user)
        ):
            """Discover available MCP tools."""
            tools = await discover_tools_endpoint(
                agent_id, provider, mcp_url, db
            )

            return success_response(
                data=tools,
                message="Tools discovered successfully"
            )
    
    return router

