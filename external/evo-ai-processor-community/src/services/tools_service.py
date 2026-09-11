"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: tools_service.py                                                      │
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

import json
import os
from typing import List, Optional, Dict, Any
from pathlib import Path

from src.schemas.tool_schemas import (
    AvailableToolsResponse,
    AvailableTool,
    ToolCategory,
    ToolsMetadata,
    AvailableToolConfig,
    ToolsFilterRequest,
)
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


class ToolsService:
    """Service for managing available tools information"""

    def __init__(self):
        """Initialize the tools service"""
        self.config_path = (
            Path(__file__).parent.parent / "config" / "available_tools.json"
        )
        self._tools_data: Optional[Dict[str, Any]] = None
        logger.info(f"Tools service initialized with config path: {self.config_path}")

    def _load_tools_config(self) -> Dict[str, Any]:
        """Load tools configuration from JSON file"""
        if self._tools_data is None:
            try:
                if not self.config_path.exists():
                    logger.error(
                        f"Tools configuration file not found: {self.config_path}"
                    )
                    raise FileNotFoundError(
                        f"Tools configuration file not found: {self.config_path}"
                    )

                with open(self.config_path, "r", encoding="utf-8") as file:
                    self._tools_data = json.load(file)
                    logger.info(
                        f"Loaded {len(self._tools_data.get('tools', []))} tools from configuration"
                    )

            except json.JSONDecodeError as e:
                logger.error(f"Error parsing tools configuration JSON: {e}")
                raise ValueError(f"Invalid JSON in tools configuration: {e}")
            except Exception as e:
                logger.error(f"Error loading tools configuration: {e}")
                raise

        return self._tools_data

    def _filter_tools(
        self, tools: List[Dict[str, Any]], filters: ToolsFilterRequest
    ) -> List[Dict[str, Any]]:
        """Apply filters to the tools list"""
        filtered_tools = tools

        # Filter by category
        if filters.category:
            try:
                tools_data = self._load_tools_config()
                categories = tools_data.get("categories", [])
                category_tools = []

                for category in categories:
                    if category.get("id") == filters.category:
                        category_tools = category.get("tools", [])
                        break

                if category_tools:
                    filtered_tools = [
                        tool
                        for tool in filtered_tools
                        if tool.get("id") in category_tools
                    ]
                else:
                    filtered_tools = []  # Category not found, return empty list

            except Exception as e:
                logger.warning(f"Error filtering by category: {e}")

        # Filter by tags
        if filters.tags:
            filtered_tools = [
                tool
                for tool in filtered_tools
                if any(tag in tool.get("tags", []) for tag in filters.tags)
            ]

        # Filter by search term
        if filters.search:
            search_term = filters.search.lower()
            filtered_tools = [
                tool
                for tool in filtered_tools
                if (
                    search_term in tool.get("name", "").lower()
                    or search_term in tool.get("description", "").lower()
                )
            ]

        return filtered_tools

    def get_available_tools(
        self, filters: Optional[ToolsFilterRequest] = None
    ) -> AvailableToolsResponse:
        """Get list of available tools with optional filtering"""
        try:
            tools_data = self._load_tools_config()

            # Get tools data
            tools_raw = tools_data.get("tools", [])

            # Apply filters if provided
            if filters:
                tools_raw = self._filter_tools(tools_raw, filters)

            # Convert to Pydantic models
            tools = []
            for tool_data in tools_raw:
                config_data = tool_data.get("config", {})
                tool_config = AvailableToolConfig(
                    required_fields=config_data.get("required_fields", []),
                    optional_fields=config_data.get("optional_fields", []),
                    default_values=config_data.get("default_values", {}),
                    field_types=config_data.get("field_types", {}),
                )

                tool = AvailableTool(
                    id=tool_data.get("id", ""),
                    name=tool_data.get("name", ""),
                    description=tool_data.get("description", ""),
                    tags=tool_data.get("tags", []),
                    examples=tool_data.get("examples", []),
                    inputModes=tool_data.get("inputModes", []),
                    outputModes=tool_data.get("outputModes", []),
                    config=tool_config,
                )
                tools.append(tool)

            # Convert categories
            categories_raw = tools_data.get("categories", [])
            categories = [
                ToolCategory(
                    id=cat.get("id", ""),
                    name=cat.get("name", ""),
                    description=cat.get("description", ""),
                    tools=cat.get("tools", []),
                )
                for cat in categories_raw
            ]

            # Convert metadata
            metadata_raw = tools_data.get("metadata", {})
            metadata = ToolsMetadata(
                version=metadata_raw.get("version", "1.0.0"),
                last_updated=metadata_raw.get("last_updated", ""),
                total_tools=len(tools),  # Use filtered count
                total_categories=len(categories),
            )

            response = AvailableToolsResponse(
                tools=tools, categories=categories, metadata=metadata
            )

            logger.info(f"Returning {len(tools)} tools, {len(categories)} categories")
            return response

        except Exception as e:
            logger.error(f"Error getting available tools: {e}")
            raise

    def get_tool_by_id(self, tool_id: str) -> Optional[AvailableTool]:
        """Get a specific tool by its ID"""
        try:
            tools_data = self._load_tools_config()
            tools_raw = tools_data.get("tools", [])

            for tool_data in tools_raw:
                if tool_data.get("id") == tool_id:
                    config_data = tool_data.get("config", {})
                    tool_config = AvailableToolConfig(
                        required_fields=config_data.get("required_fields", []),
                        optional_fields=config_data.get("optional_fields", []),
                        default_values=config_data.get("default_values", {}),
                        field_types=config_data.get("field_types", {}),
                    )

                    tool = AvailableTool(
                        id=tool_data.get("id", ""),
                        name=tool_data.get("name", ""),
                        description=tool_data.get("description", ""),
                        tags=tool_data.get("tags", []),
                        examples=tool_data.get("examples", []),
                        inputModes=tool_data.get("inputModes", []),
                        outputModes=tool_data.get("outputModes", []),
                        config=tool_config,
                    )

                    logger.info(f"Found tool: {tool_id}")
                    return tool

            logger.warning(f"Tool not found: {tool_id}")
            return None

        except Exception as e:
            logger.error(f"Error getting tool by ID {tool_id}: {e}")
            raise

    def get_categories(self) -> List[ToolCategory]:
        """Get list of tool categories"""
        try:
            tools_data = self._load_tools_config()
            categories_raw = tools_data.get("categories", [])

            categories = [
                ToolCategory(
                    id=cat.get("id", ""),
                    name=cat.get("name", ""),
                    description=cat.get("description", ""),
                    tools=cat.get("tools", []),
                )
                for cat in categories_raw
            ]

            logger.info(f"Returning {len(categories)} categories")
            return categories

        except Exception as e:
            logger.error(f"Error getting categories: {e}")
            raise

    def reload_config(self) -> bool:
        """Reload tools configuration from file"""
        try:
            self._tools_data = None  # Clear cache
            self._load_tools_config()  # Reload
            logger.info("Tools configuration reloaded successfully")
            return True
        except Exception as e:
            logger.error(f"Error reloading tools configuration: {e}")
            return False


# Global instance
tools_service = ToolsService()
