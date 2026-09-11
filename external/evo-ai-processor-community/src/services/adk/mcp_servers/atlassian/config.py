"""
Atlassian MCP server configuration.

This module provides configuration for connecting to the Atlassian MCP server.
It fetches OAuth credentials from the agent's integration configuration.
"""

import logging
from typing import Optional, Dict, Any
from sqlalchemy.orm import Session

logger = logging.getLogger(__name__)

# Default Atlassian MCP URL
default_url = "https://mcp.atlassian.com/mcp"


async def get_atlassian_mcp_config(
    agent_id: str,
    db: Optional[Session] = None
) -> Dict[str, Any]:
    """
    Get Atlassian MCP server configuration for an agent.

    Args:
        agent_id: Agent ID
        db: Optional database session for direct database access

    Returns:
        Dictionary with MCP server configuration including:
        - url: MCP server URL
        - headers: Authorization headers with access token
        - tools: List of selected tools (if any)
    """
    config: Dict[str, Any] = {
        "url": default_url,
        "headers": {},
        "tools": []
    }

    # If database session is provided, fetch integration config directly
    if db:
        try:
            from src.services.agent_service import get_agent_integrations

            # Get agent integrations
            integrations = await get_agent_integrations(db, agent_id)

            # Find Atlassian integration
            atlassian_integration = None
            for integration in integrations:
                if integration.get("provider", "").lower() == "atlassian":
                    atlassian_integration = integration
                    break

            if atlassian_integration:
                integration_config = atlassian_integration.get("config", {})
                access_token = integration_config.get("access_token")
                mcp_url = integration_config.get("mcp_url", default_url)
                tools = integration_config.get("tools", [])

                if access_token:
                    config["url"] = mcp_url
                    config["headers"]["Authorization"] = f"Bearer {access_token}"
                    config["tools"] = tools

                    logger.info(
                        f"Atlassian MCP config loaded for agent {agent_id}: "
                        f"url={mcp_url}, tools={len(tools)}"
                    )
                else:
                    logger.warning(
                        f"Atlassian integration found for agent {agent_id} but no access_token"
                    )
            else:
                logger.debug(f"No Atlassian integration found for agent {agent_id}")
        except Exception as e:
            logger.error(f"Error loading Atlassian MCP config from database: {e}")

    return config

