"""
GitHub MCP server configuration.

This module provides the configuration for connecting to GitHub's MCP server
using OAuth credentials stored in the agent's integration settings.
"""

from typing import Dict, Any, Optional
import os
from sqlalchemy.orm import Session
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


async def get_github_mcp_config(
    agent_id: str,
    mcp_url: Optional[str] = None,
    db: Optional[Session] = None
) -> Dict[str, Any]:
    """
    Get GitHub MCP server configuration with OAuth headers and tool filtering.

    Args:
        agent_id: Agent ID
        mcp_url: Optional custom MCP URL (defaults to GitHub Copilot MCP)

    Returns:
        Dictionary with MCP server configuration including OAuth headers and tools list
    """
    # Default GitHub Copilot MCP URL
    default_url = "https://api.githubcopilot.com/mcp/"
    url = mcp_url or default_url

    config = {
        "type": "http",
        "url": url,
        "headers": {},
        "tools": []  # Tools to filter (empty = all tools)
    }

    # Try to get OAuth headers and tools configuration from integration
    try:
        # Load integration directly from database if db is available
        integration_config = None
        if db:
            from src.services.agent_service import get_agent_integrations
            import uuid
            try:
                integrations = await get_agent_integrations(db, agent_id)
                for integration in integrations:
                    if integration.get("provider", "").lower() == "github":
                        integration_config = integration.get("config", {})
                        break
            except Exception as db_error:
                logger.debug(f"Could not load GitHub integration from database: {db_error}")

        # If we have integration config from database, use it
        if integration_config:
            access_token = integration_config.get("access_token")
            if access_token:
                config["headers"]["Authorization"] = f"Bearer {access_token}"
                logger.info(f"Successfully loaded OAuth headers for GitHub MCP server from database")
                
                selected_tools = integration_config.get("tools", [])
                if selected_tools:
                    config["tools"] = selected_tools
                    logger.info(
                        f"Loaded {len(selected_tools)} selected GitHub tools for agent {agent_id}: "
                        f"{', '.join(selected_tools[:5])}" + (" ..." if len(selected_tools) > 5 else "")
                    )
                else:
                    logger.info(f"No specific tools selected for GitHub integration, all tools will be available")
            else:
                logger.warning(f"GitHub integration found but access_token is missing")
        else:
            # Fallback to HTTP call if db not available
            from src.services.mcp_oauth_service import MCPOAuthService
            core_service_url = os.getenv("CORE_SERVICE_URL", "http://localhost:5555/api/v1")
            oauth_service = MCPOAuthService(
                mcp_url=url,
                redirect_uri="",
                core_service_url=core_service_url,
                user_token="",
                provider_name="github"
            )
            oauth_headers = await oauth_service.get_mcp_headers(
                agent_id=agent_id,
                mcp_url=url
            )
            config["headers"].update(oauth_headers)
            logger.info(f"Successfully loaded OAuth headers for GitHub MCP server via HTTP")

    except Exception as e:
        logger.warning(
            f"Failed to load OAuth headers for GitHub MCP server: {e}. "
            f"Make sure GitHub OAuth is configured for agent {agent_id}."
        )
        # Return config without OAuth headers - connection will fail but config is valid
        pass

    return config
