"""
HubSpot MCP server configuration.

Fetches HubSpot integration configuration directly from the database
to avoid HTTP calls to core-service during agent execution.
Automatically refreshes expired tokens using refresh_token.
"""

import logging
from typing import Optional, Dict, Any
from datetime import datetime, timezone, timedelta
from sqlalchemy.orm import Session

from src.services.agent_service import get_agent_integrations

logger = logging.getLogger(__name__)


async def get_hubspot_mcp_config(
    agent_id: str,
    db: Optional[Session] = None
) -> Optional[Dict[str, Any]]:
    """
    Get HubSpot MCP server configuration for an agent.

    Fetches integration configuration directly from the database.
    Automatically refreshes expired tokens using refresh_token.

    Args:
        agent_id: Agent ID
        db: Database session (optional, will create if not provided)

    Returns:
        MCP server configuration dict or None if not configured
    """
    try:
        if not db:
            logger.warning("No database session provided for HubSpot MCP config")
            return None

        # Fetch all integrations for this agent
        integrations = await get_agent_integrations(db, agent_id)

        # Find HubSpot integration
        hubspot_integration = None
        for integration in integrations:
            if integration.get("provider", "").lower() == "hubspot":
                hubspot_integration = integration
                break

        if not hubspot_integration:
            logger.debug(f"No HubSpot integration found for agent {agent_id}")
            return None

        config = hubspot_integration.get("config", {})
        access_token = config.get("access_token")
        refresh_token = config.get("refresh_token")
        mcp_url = config.get("mcp_url", "https://mcp.hubspot.com/mcp")
        tools = config.get("tools", [])
        expires_at = config.get("expires_at")
        expires_in = config.get("expires_in")

        logger.info(
            f"HubSpot MCP config check for agent {agent_id}: "
            f"has_access_token={bool(access_token)}, "
            f"has_refresh_token={bool(refresh_token)}, "
            f"expires_at={expires_at}, "
            f"expires_in={expires_in}"
        )

        if not access_token:
            logger.debug(f"HubSpot integration found but no access_token for agent {agent_id}")
            return None

        # Check if token is expired or near expiration (within 5 minutes)
        should_refresh = False
        if expires_at:
            try:
                # Parse expires_at - handle different formats
                expires_str = expires_at.replace('Z', '+00:00')
                expires_dt = datetime.fromisoformat(expires_str)
                
                # Ensure expires_dt is timezone-aware
                if expires_dt.tzinfo is None:
                    expires_dt = expires_dt.replace(tzinfo=timezone.utc)
                
                now = datetime.now(timezone.utc)
                # Refresh if expired or expires within 5 minutes
                if expires_dt <= now + timedelta(minutes=5):
                    should_refresh = True
                    logger.info(
                        f"HubSpot access_token expired or expiring soon for agent {agent_id}. "
                        f"Expires at: {expires_at}, Current time: {now.isoformat()}. "
                        f"Will attempt refresh."
                    )
            except Exception as e:
                logger.warning(f"Could not parse expires_at for HubSpot token: {e}")
                # If we can't parse expiration, try refresh if refresh_token is available
                if refresh_token:
                    should_refresh = True
        elif refresh_token:
            # No expiration info but refresh_token available - try refresh
            logger.info(
                f"HubSpot token has no expires_at but refresh_token available. "
                f"Will attempt refresh for agent {agent_id}."
            )
            should_refresh = True

        # Refresh token if needed
        logger.info(
            f"HubSpot refresh check: should_refresh={should_refresh}, "
            f"has_refresh_token={bool(refresh_token)}"
        )
        
        if should_refresh and refresh_token:
            logger.info(
                f"Attempting to refresh HubSpot token for agent {agent_id}"
            )
            try:
                from src.services.hubspot_service import HubSpotService
                from src.services.global_config_service import GlobalConfigService
                
                # Load global config to get HubSpot OAuth credentials
                global_config_service = GlobalConfigService()
                hubspot_creds = await global_config_service.get_hubspot_credentials()
                
                logger.info(
                    f"HubSpot global config loaded: "
                    f"has_client_id={bool(hubspot_creds and hubspot_creds.get('client_id'))}, "
                    f"has_client_secret={bool(hubspot_creds and hubspot_creds.get('client_secret'))}"
                )
                
                if not hubspot_creds or not hubspot_creds.get("client_id") or not hubspot_creds.get("client_secret"):
                    logger.warning(
                        f"HubSpot OAuth credentials not found in global config. "
                        f"Cannot refresh token. Using existing token (may be expired)."
                    )
                else:
                    # Create HubSpotService instance for refresh
                    hubspot_service = HubSpotService(
                        client_id=hubspot_creds["client_id"],
                        client_secret=hubspot_creds["client_secret"],
                        redirect_uri=hubspot_creds.get("redirect_uri", ""),
                        core_service_url="",  # Not needed for refresh
                        user_token="",  # Not needed for refresh
                        mcp_url=mcp_url
                    )
                    
                    # Attempt to refresh token
                    new_access_token = await hubspot_service.refresh_access_token(
                        agent_id=agent_id,
                        mcp_url=mcp_url,
                        db=db
                    )
                    
                    if new_access_token:
                        # Update access_token in config
                        access_token = new_access_token
                        logger.info(
                            f"HubSpot access_token refreshed successfully for agent {agent_id}. "
                            f"New token length: {len(new_access_token)}"
                        )
                    else:
                        logger.warning(
                            f"HubSpot token refresh failed for agent {agent_id}. "
                            f"Using existing token (may be expired)."
                        )
            except Exception as refresh_error:
                logger.error(
                    f"Error refreshing HubSpot token for agent {agent_id}: {refresh_error}",
                    exc_info=True
                )
                # Continue with existing token (may be expired)

        # Build MCP server configuration
        # HubSpot tokens may start with "CIT-" or "CKGP-" (Client Initiated Token)
        # These are OAuth access tokens and should use Bearer format
        # Note: Some HubSpot APIs may accept tokens without Bearer prefix, but MCP likely requires Bearer
        token_starts_with = access_token[:4] if len(access_token) >= 4 else ""
        
        # Always use Bearer format for OAuth tokens (standard OAuth 2.0)
        # Even if token starts with CIT- or CKGP-, it's still an OAuth access token
        auth_header = f"Bearer {access_token}"
        
        mcp_config = {
            "url": mcp_url,
            "type": "http",
            "headers": {
                "Authorization": auth_header,
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Connection": "keep-alive",  # Ensure persistent connection for StreamableHTTP
            },
            "tools": tools,
        }

        # Log token info (masked for security)
        token_preview = access_token[:10] + "..." + access_token[-10:] if len(access_token) > 20 else "***masked***"
        logger.info(
            f"HubSpot MCP config loaded for agent {agent_id}. "
            f"Token preview: {token_preview}, "
            f"Token starts with: {token_starts_with}, "
            f"Token length: {len(access_token)}, "
            f"Expires at: {expires_at}, "
            f"Expires in: {expires_in}s, "
            f"Tools: {len(tools)}"
        )
        return mcp_config

    except Exception as e:
        logger.error(f"Error loading HubSpot MCP config: {e}")
        return None

