"""
Monday MCP server configuration.

Fetches Monday integration configuration from the database and prepares
it for use with the MCP client.
"""

from typing import Optional, Dict, Any
from sqlalchemy.orm import Session
from src.utils.logger import setup_logger

from src.services.agent_service import get_agent_integrations

logger = setup_logger(__name__)


async def get_monday_mcp_config(
    agent_id: str,
    mcp_url: Optional[str] = None,
    db: Optional[Session] = None
) -> Dict[str, Any]:
    """
    Get Monday MCP server configuration.

    Args:
        agent_id: Agent ID
        mcp_url: Optional custom MCP URL (defaults to Monday MCP)
        db: Optional database session for direct database access

    Returns:
        Dictionary with MCP server configuration
    """
    default_url = "https://mcp.monday.com/mcp"
    effective_url = mcp_url or default_url

    config: Dict[str, Any] = {
        "type": "http",
        "url": effective_url,
        "headers": {},
        "tools": []
    }

    # If database session is provided, fetch integration config directly
    if db:
        try:
            integrations = await get_agent_integrations(db, agent_id)
            
            # Find Monday integration
            monday_integration = None
            for integration in integrations:
                if integration.get("provider", "").lower() == "monday":
                    monday_integration = integration
                    break

            if monday_integration:
                integration_config = monday_integration.get("config", {})
                access_token = integration_config.get("access_token")
                tools = integration_config.get("tools", [])
                mcp_url_from_config = integration_config.get("mcp_url", default_url)

                logger.info(
                    f"Monday integration found for agent {agent_id}: "
                    f"has_token={bool(access_token)}, "
                    f"tools_count={len(tools) if tools else 0}, "
                    f"mcp_url={mcp_url_from_config}"
                )

                if access_token:
                    config["headers"]["Authorization"] = f"Bearer {access_token}"
                    config["url"] = mcp_url_from_config  # Use URL from integration config
                    logger.info(f"Monday MCP config loaded with access token for agent {agent_id}")
                else:
                    logger.warning(f"Monday integration found but no access token for agent {agent_id}")

                # Store selected tools in config for filtering (always set, even if empty)
                config["tools"] = tools if tools else []
                if tools:
                    logger.info(f"Monday MCP config includes {len(tools)} selected tools: {tools[:5]}...")
                else:
                    logger.info(f"Monday MCP config: no tools selected, will use all available tools")
            else:
                logger.debug(f"No Monday integration found for agent {agent_id}")
        except Exception as e:
            logger.error(f"Error loading Monday integration config from database: {e}")

    return config

