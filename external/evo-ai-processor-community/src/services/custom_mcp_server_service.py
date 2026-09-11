"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: custom_mcp_server_service.py                                         │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 14, 2025                                              │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
│                                                                              │
│ You may not use this file except in compliance with the License.             │
│ You may obtain a copy of the License at                                      │
│                                                                              │
│    http://www.apache.org/licenses/LICENSE-2.0                                │
│                                                                              │
│ Unless required by applicable law or agreed to in writing, software          │
│ distributed under the License is distributed on an "AS IS" BASIS,            │
│ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     │
│ See the License for the specific language governing permissions and          │
│ limitations under the License.                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│ @important                                                                   │
│ For any future changes to the code in this file, it is recommended to        │
│ include, together with the modification, the information of the developer    │
│ who changed it and the date of modification.                                 │
└──────────────────────────────────────────────────────────────────────────────┘
"""

from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError
from fastapi import HTTPException, status
from src.models.models import CustomMCPServer
from src.schemas.schemas import CustomMCPDiscoverToolsCreate
from typing import List, Optional, Dict, Any
import time
import uuid
import logging
from src.utils.mcp_discovery import _discover_async

logger = logging.getLogger(__name__)


def get_custom_mcp_server(
    db: Session, server_id: uuid.UUID
) -> Optional[CustomMCPServer]:
    """Get a custom MCP server by ID"""
    try:
        return db.query(CustomMCPServer).filter(CustomMCPServer.id == server_id).first()
    except SQLAlchemyError as e:
        logger.error(f"Error getting custom MCP server {server_id}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Error getting custom MCP server",
        )

def convert_to_mcp_server_config(custom_server: CustomMCPServer) -> Dict[str, Any]:
    """Convert CustomMCPServer to MCP server config format for agent configuration"""
    return {
        "url": custom_server.url,
        "headers": custom_server.headers,
    }


async def test_custom_mcp_server_connection(
    test_request: CustomMCPDiscoverToolsCreate,
) -> Dict[str, Any]:
    """Test connection to a custom MCP server via MCP handshake.

    EVO-2139: reuses `_discover_async` (Google ADK MCPToolset), which speaks
    the real MCP protocol (POST JSON-RPC 2.0 `initialize` over Streamable
    HTTP). The previous implementation did a `GET /health` — a route MCP
    servers do not expose — and failed for every compliant server.
    """
    url = test_request.url or ""
    start = time.perf_counter()

    try:
        tools = await _discover_async({
            "url": url,
            "headers": test_request.headers or {},
        })
        elapsed = time.perf_counter() - start
        tools_count = len(tools)

        return {
            "success": True,
            "status_code": 200,
            "response_time": elapsed,
            "url_tested": url,
            "tools_count": tools_count,
            "message": f"Connection successful, discovered {tools_count} tools",
        }
    except Exception as e:
        elapsed = time.perf_counter() - start
        error_message = str(e)
        logger.error(f"MCP test connection failed for {url}: {error_message}")

        return {
            "success": False,
            "error": error_message,
            "url_tested": url,
            "response_time": elapsed,
        }


def get_custom_mcp_servers_for_agent_config(
    db: Session, server_ids: List[uuid.UUID]
) -> List[Dict[str, Any]]:
    """Get custom MCP servers for agent configuration by IDs"""
    try:
        servers = (
            db.query(CustomMCPServer)
            .filter(
                CustomMCPServer.id.in_(server_ids),
            )
            .all()
        )

        return [convert_to_mcp_server_config(server) for server in servers]
    except SQLAlchemyError as e:
        logger.error(f"Error getting custom MCP servers for agent config: {str(e)}")
        return []


async def discover_custom_mcp_server_tools(
    discover_tools: CustomMCPDiscoverToolsCreate,
) -> Dict[str, Any]:
    """Discover tools from a custom MCP server"""
    try:
        logger.info(f"Discovering tools from URL: {discover_tools.url}")
        logger.info(f"Headers: {discover_tools.headers}")

        tools = await _discover_async({
            "url": discover_tools.url,
            "headers": discover_tools.headers or {},
        })

        logger.info(f"Discovered {len(tools)} tools")
        return {
            "success": True,
            "tools": tools,
        }

    except Exception as e:
        logger.error(f"Error discovering tools: {str(e)}")
        import traceback
        logger.error(traceback.format_exc())
        return {
            "success": False,
            "error": str(e)
        }
