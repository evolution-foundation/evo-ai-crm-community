"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: custom_mcp_servers_routes.py                                         │
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

from fastapi import APIRouter, status, Depends, Request
from src.schemas.schemas import (
    CustomMCPDiscoverToolsCreate,
    CustomMCPDiscoverToolsResponse
)
from src.services import custom_mcp_server_service
from src.api.dependencies import get_current_user
from src.middleware.permissions import RequirePermission
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from src.schemas.response_models import DiscoverToolsResponse
import logging

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/custom-mcp-servers",
    tags=["custom-mcp-servers"],
)

@router.post(
    "/discover-tools",
    response_model=SuccessResponse[DiscoverToolsResponse],
    responses={
        200: {"description": "Tools discovered successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def create_discover_tools(
    discover_tools: CustomMCPDiscoverToolsCreate,
    # discover-tools enumera as tools de um servidor MCP = uma LEITURA. Usa a action
    # "read" (que existe no catálogo do auth e é grantada a quem tem create/list),
    # não "discover" — essa action NÃO existe em resource_actions_config → 403 pra
    # todos. Os endpoints-irmãos de discover (canva/asana) nem têm gate; este era o
    # único, com uma action fantasma. Coerência: read.
    permission: None = Depends(RequirePermission("ai_custom_mcp_servers", "read")),
    _: dict = Depends(get_current_user),
):
    """Discover tools from a custom MCP server"""
    
    logger.info(f"🔍 Discover tools endpoint called for URL: {discover_tools.url}")
    
    try:
        result = await custom_mcp_server_service.discover_custom_mcp_server_tools(
            discover_tools
        )
        
        if result.get("success") is False:
            error_msg = result.get("error", "Unknown error")
            logger.error(f"Error discovering tools: {error_msg}")
            # Return empty tools list instead of raising exception
            # This allows the Go service to handle the error gracefully
            return CustomMCPDiscoverToolsResponse(tools=[])
        
        discovered_tools = result.get("tools", [])
        logger.info(f"Discovered {len(discovered_tools)} tools from custom MCP server")
        
        return success_response(
            data=discovered_tools,
            message=f"Discovered {len(discovered_tools)} tools from custom MCP server"
        )
        
    except Exception as e:
        logger.error(f"Unexpected error discovering tools: {str(e)}")
        return error_response(
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error discovering tools: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.post(
    "/test-connection",
    responses={
        200: {"description": "Test result returned (success or failure inside body)"},
        500: {"model": ErrorResponse, "description": "Internal server error"},
    },
)
async def test_connection(
    test_request: CustomMCPDiscoverToolsCreate,
    # EVO-2139: same permission model as discover-tools — testing enumerates
    # the tools (via MCP `initialize`) which is a read operation on the server
    # config. The Go core-service already gates the caller by resource; here
    # we just verify the user can read ai_custom_mcp_servers.
    permission: None = Depends(RequirePermission("ai_custom_mcp_servers", "read")),
    _: dict = Depends(get_current_user),
):
    """Test connection to a custom MCP server via MCP handshake.

    EVO-2139: Go `service.Test()` delegates here instead of doing a raw
    `GET /health` check that never worked for real MCP servers.
    """
    logger.info(f"🔌 Test connection endpoint called for URL: {test_request.url}")

    try:
        result = await custom_mcp_server_service.test_custom_mcp_server_connection(
            test_request
        )
        # Always 200 with the result envelope — success/failure lives inside
        # `success`. This matches the discover-tools pattern and lets the Go
        # side render failures cleanly instead of surfacing 500s to the UI.
        return result
    except Exception as e:
        logger.error(f"Unexpected error testing connection: {str(e)}")
        return error_response(
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error testing connection: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )
