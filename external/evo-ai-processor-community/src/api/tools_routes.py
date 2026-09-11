"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: tools_routes.py                                                       │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: January 27, 2025                                              │
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

from fastapi import APIRouter, HTTPException, status, Query, Depends, Request
from typing import Optional
from src.api.dependencies import get_current_user

from src.schemas.tool_schemas import (
    ToolsFilterRequest,
    AvailableToolsResponse,
    AvailableTool,
    ToolCategory,
)
from src.services.tools_service import tools_service
from src.utils.logger import setup_logger
from src.middleware.permissions import RequirePermission
from src.utils.response import success_response, error_response, map_status_to_error_code
from src.schemas.responses import SuccessResponse, ErrorResponse
from typing import List as TypingList

logger = setup_logger(__name__)

router = APIRouter(
    prefix="/tools",
    tags=["tools"],
)


@router.get(
    "",
    response_model=SuccessResponse[AvailableToolsResponse],
    responses={
        200: {"description": "Tools retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def list_available_tools(
    request: Request,
    category: Optional[str] = Query(None, description="Filter by category ID"),
    tags: Optional[str] = Query(None, description="Filter by tags (comma-separated)"),
    search: Optional[str] = Query(None, description="Search in name and description"),
    permission: None = Depends(RequirePermission("ai_tools", "available")),
    _: dict = Depends(get_current_user)
):
    """List all available tools with optional filtering"""
    try:
        # Parse tags if provided
        tag_list = None
        if tags:
            tag_list = [tag.strip() for tag in tags.split(",") if tag.strip()]

        # Create filter request
        filters = None
        if category or tag_list or search:
            filters = ToolsFilterRequest(
                category=category, tags=tag_list, search=search
            )

        # Get tools from service
        tools_response = tools_service.get_available_tools(filters)

        logger.info(
            f"Listed {len(tools_response.tools)} tools "
            f"(filtered: {filters is not None})"
        )

        return success_response(
            data=tools_response.model_dump(),
            message="Tools retrieved successfully"
        )

    except Exception as e:
        logger.error(f"Error listing available tools: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error listing available tools: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.get(
    "/{tool_id}",
    response_model=SuccessResponse[AvailableTool],
    responses={
        200: {"description": "Tool retrieved successfully"},
        404: {"model": ErrorResponse, "description": "Tool not found"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def get_tool_details(
    tool_id: str,
    request: Request,
    permission: None = Depends(RequirePermission("ai_tools", "read")),
    _: dict = Depends(get_current_user)
):
    """Get details of a specific tool"""
    try:
        tool = tools_service.get_tool_by_id(tool_id)

        if not tool:
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_404_NOT_FOUND),
                message=f"Tool not found: {tool_id}",
                status_code=status.HTTP_404_NOT_FOUND
            )

        logger.info(f"Retrieved tool details: {tool_id}")
        return success_response(
            data=tool.model_dump(),
            message="Tool retrieved successfully"
        )
    except Exception as e:
        logger.error(f"Error getting tool details for {tool_id}: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error getting tool details: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.get(
    "/categories/list",
    response_model=SuccessResponse[TypingList[ToolCategory]],
    responses={
        200: {"description": "Tool categories retrieved successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def list_tool_categories(
    request: Request,
    permission: None = Depends(RequirePermission("ai_tools", "categories")),
    _: dict = Depends(get_current_user)
):
    """List all tool categories"""
    try:
        categories = tools_service.get_categories()

        logger.info(f"Listed {len(categories)} tool categories")
        return success_response(
            data=[cat.model_dump() for cat in categories],
            message="Tool categories retrieved successfully"
        )

    except Exception as e:
        logger.error(f"Error listing tool categories: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error listing tool categories: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )


@router.post(
    "/reload-config",
    response_model=SuccessResponse[None],
    responses={
        200: {"description": "Tools configuration reloaded successfully"},
        500: {"model": ErrorResponse, "description": "Internal server error"}
    }
)
async def reload_tools_config(
    request: Request,
    permission: None = Depends(RequirePermission("ai_tools", "config")),
    _: dict = Depends(get_current_user)
):
    """Reload tools configuration from file (admin only)"""
    try:
        success = tools_service.reload_config()

        if success:
            logger.info("Tools configuration reloaded successfully")
            return success_response(
                data=None,
                message="Tools configuration reloaded successfully",
                status_code=200
            )
        else:
            return error_response(
                request=request,
                code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
                message="Failed to reload tools configuration",
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
            )
    except Exception as e:
        logger.error(f"Error reloading tools configuration: {str(e)}")
        return error_response(
            request=request,
            code=map_status_to_error_code(status.HTTP_500_INTERNAL_SERVER_ERROR),
            message=f"Error reloading tools configuration: {str(e)}",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
